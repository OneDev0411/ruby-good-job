module GoodJob
  #
  # Represents a request to perform an +ActiveJob+ job.
  #
  class Job < ActiveRecord::Base
    include Lockable

    # Raised if something attempts to execute a previously completed Job again.
    PreviouslyPerformedError = Class.new(StandardError)

    # ActiveJob jobs without a +queue_name+ attribute are placed on this queue.
    DEFAULT_QUEUE_NAME = 'default'.freeze
    # ActiveJob jobs without a +priority+ attribute are given this priority.
    DEFAULT_PRIORITY = 0

    self.table_name = 'good_jobs'.freeze

    # Parse a string representing a group of queues into a more readable data
    # structure.
    # @return [Hash]
    #   How to match a given queue. It can have the following keys and values:
    #   - +{ all: true }+ indicates that all queues match.
    #   - +{ exclude: Array<String> }+ indicates the listed queue names should
    #     not match.
    #   - +{ include: Array<String> }+ indicates the listed queue names should
    #     match.
    # @example
    #   GoodJob::Job.queue_parser('-queue1,queue2')
    #   => { exclude: [ 'queue1', 'queue2' ] }
    def self.queue_parser(string)
      string = string.presence || '*'

      if string.first == '-'
        exclude_queues = true
        string = string[1..-1]
      end

      queues = string.split(',').map(&:strip)

      if queues.include?('*')
        { all: true }
      elsif exclude_queues
        { exclude: queues }
      else
        { include: queues }
      end
    end

    # Get Jobs that have not yet been completed.
    # @!method unfinished
    # @!scope class
    # @return [ActiveRecord::Relation]
    scope :unfinished, (lambda do
      if column_names.include?('finished_at')
        where(finished_at: nil)
      else
        ActiveSupport::Deprecation.warn('GoodJob expects a good_jobs.finished_at column to exist. Please see the GoodJob README.md for migration instructions.')
        nil
      end
    end)

    # Get Jobs that are not scheduled for a later time than now (i.e. jobs that
    # are not scheduled or scheduled for earlier than the current time).
    # @!method only_scheduled
    # @!scope class
    # @return [ActiveRecord::Relation]
    scope :only_scheduled, -> { where(arel_table['scheduled_at'].lteq(Time.current)).or(where(scheduled_at: nil)) }

    # Order jobs by priority (highest priority first).
    # @!method priority_ordered
    # @!scope class
    # @return [ActiveRecord::Relation]
    scope :priority_ordered, -> { order('priority DESC NULLS LAST') }

    # Get Jobs were completed before the given timestamp. If no timestamp is
    # provided, get all jobs that have been completed. By default, GoodJob
    # deletes jobs after they are completed and this will find no jobs.
    # However, if you have changed {GoodJob.preserve_job_records}, this may
    # find completed Jobs.
    # @!method finished(timestamp = nil)
    # @!scope class
    # @param timestamp (Float)
    #   Get jobs that finished before this time (in epoch time).
    # @return [ActiveRecord::Relation]
    scope :finished, ->(timestamp = nil) { timestamp ? where(arel_table['finished_at'].lteq(timestamp)) : where.not(finished_at: nil) }

    # Get Jobs on queues that match the given queue string.
    # @!method queue_string(string)
    # @!scope class
    # @param string [String]
    #   A string expression describing what queues to select. See
    #   {Job.queue_parser} or
    #   {file:README.md#optimize-queues-threads-and-processes} for more details
    #   on the format of the string. Note this only handles individual
    #   semicolon-separated segments of that string format.
    # @return [ActiveRecord::Relation]
    scope :queue_string, (lambda do |string|
      parsed = queue_parser(string)

      if parsed[:all]
        all
      elsif parsed[:exclude]
        where.not(queue_name: parsed[:exclude]).or where(queue_name: nil)
      elsif parsed[:include]
        where(queue_name: parsed[:include])
      end
    end)

    # Finds the next eligible Job, acquire an advisory lock related to it, and
    # executes the job.
    # @return [Array<(GoodJob::Job, Object, Exception)>, nil]
    #   If a job was executed, returns an array with the {Job} record, the
    #   return value for the job's +#perform+ method, and the exception the job
    #   raised, if any (if the job raised, then the second array entry will be
    #   +nil+). If there were no jobs to execute, returns +nil+.
    def self.perform_with_advisory_lock
      good_job = nil
      result = nil
      error = nil

      unfinished.priority_ordered.only_scheduled.limit(1).with_advisory_lock do |good_jobs|
        good_job = good_jobs.first
        # TODO: Determine why some records are fetched without an advisory lock at all
        break unless good_job&.owns_advisory_lock?

        result, error = good_job.perform
      end

      [good_job, result, error] if good_job
    end

    # Places an ActiveJob job on a queue by creating a new {Job} record.
    # @param active_job [ActiveJob::Base]
    #   The job to enqueue.
    # @param scheduled_at [Float]
    #   Epoch timestamp when the job should be executed.
    # @param create_with_advisory_lock [Boolean]
    #   Whether to establish a lock on the {Job} record after it is created.
    # @return [Job]
    #   The new {Job} instance representing the queued ActiveJob job.
    def self.enqueue(active_job, scheduled_at: nil, create_with_advisory_lock: false)
      good_job = nil
      ActiveSupport::Notifications.instrument("enqueue_job.good_job", { active_job: active_job, scheduled_at: scheduled_at, create_with_advisory_lock: create_with_advisory_lock }) do |instrument_payload|
        good_job = GoodJob::Job.new(
          queue_name: active_job.queue_name.presence || DEFAULT_QUEUE_NAME,
          priority: active_job.priority || DEFAULT_PRIORITY,
          serialized_params: active_job.serialize,
          scheduled_at: scheduled_at,
          create_with_advisory_lock: create_with_advisory_lock
        )

        instrument_payload[:good_job] = good_job

        good_job.save!
        active_job.provider_job_id = good_job.id
      end

      good_job
    end

    # Execute the ActiveJob job this {Job} represents.
    # @param destroy_after [Boolean]
    #   Whether to destroy the {Job} record after executing it if the job did
    #   not need to be reperformed. Defaults to the value of
    #   {GoodJob.preserve_job_records}.
    # @param reperform_on_standard_error [Boolean]
    #   Whether to re-queue the job to execute again if it raised an instance
    #   of +StandardError+. Defaults to the value of
    #   {GoodJob.reperform_jobs_on_standard_error}.
    # @return [Array<(Object, Exception)>]
    #   An array of the return value of the job's +#perform+ method and the
    #   exception raised by the job, if any. If the job completed successfully,
    #   the second array entry (the exception) will be +nil+ and vice versa.
    def perform(destroy_after: !GoodJob.preserve_job_records, reperform_on_standard_error: GoodJob.reperform_jobs_on_standard_error)
      raise PreviouslyPerformedError, 'Cannot perform a job that has already been performed' if finished_at

      GoodJob::CurrentExecution.reset
      result = nil
      rescued_error = nil
      error = nil

      self.performed_at = Time.current
      save! unless destroy_after

      params = serialized_params.merge(
        "provider_job_id" => id
      )

      begin
        ActiveSupport::Notifications.instrument("perform_job.good_job", { good_job: self, process_id: GoodJob::CurrentExecution.process_id, thread_name: GoodJob::CurrentExecution.thread_name }) do
          result = ActiveJob::Base.execute(params)
        end
      rescue StandardError => e
        rescued_error = e
      end

      retry_or_discard_error = GoodJob::CurrentExecution.error_on_retry ||
                               GoodJob::CurrentExecution.error_on_discard

      if rescued_error
        error = rescued_error
      elsif result.is_a?(Exception)
        error = result
        result = nil
      elsif retry_or_discard_error
        error = retry_or_discard_error
      end

      error_message = "#{error.class}: #{error.message}" if error
      self.error = error_message

      if rescued_error && reperform_on_standard_error
        save!
      else
        self.finished_at = Time.current

        if destroy_after
          destroy!
        else
          save!
        end
      end

      [result, error]
    end
  end
end
