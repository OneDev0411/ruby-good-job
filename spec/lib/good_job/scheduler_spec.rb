require 'rails_helper'

RSpec.describe GoodJob::Scheduler do
  let(:performer) { instance_double(GoodJob::Performer, next: nil, name: '') }

  after do
    described_class.instances.each(&:shutdown)
  end

  context 'when thread error' do
    let(:error_proc) { double("Error Collector", call: nil) } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(GoodJob).to receive(:on_thread_error).and_return(error_proc)
      stub_const 'THREAD_HAS_RUN', Concurrent::AtomicBoolean.new(false)
    end

    context 'when on task thread' do
      it 'calls GoodJob.on_thread_error' do
        allow(performer).to receive(:next) do
          THREAD_HAS_RUN.make_true
          raise "Whoops"
        end

        scheduler = described_class.new(performer)
        scheduler.create_thread
        sleep_until { THREAD_HAS_RUN.true? }

        expect(error_proc).to have_received(:call).with(an_instance_of(RuntimeError).and(having_attributes(message: 'Whoops')))

        scheduler.shutdown
      end
    end
  end

  describe '.instances' do
    it 'contains all registered instances' do
      scheduler = nil
      expect do
        scheduler = described_class.new(performer)
      end.to change { described_class.instances.size }.by(1)

      expect(described_class.instances).to include scheduler
    end
  end

  describe '#shutdown' do
    it 'shuts down the theadpools' do
      scheduler = described_class.new(performer)

      scheduler.shutdown

      expect(scheduler.instance_variable_get(:@pool).running?).to be false
    end
  end

  describe '#restart' do
    it 'restarts the threadpools' do
      scheduler = described_class.new(performer)
      scheduler.shutdown

      scheduler.restart

      expect(scheduler.instance_variable_get(:@pool).running?).to be true
    end
  end

  describe '#create_thread' do
    it 'returns false if there are no threads available' do
      configuration = GoodJob::Configuration.new({ queues: 'mice:1' })
      scheduler = described_class.from_configuration(configuration)

      scheduler.create_thread(queue_name: 'mice')
      expect(scheduler.create_thread(queue_name: 'mice')).to eq nil
    end

    it 'returns true if the state matches the performer' do
      configuration = GoodJob::Configuration.new({ queues: 'mice:2' })
      scheduler = described_class.from_configuration(configuration)

      expect(scheduler.create_thread(queue_name: 'mice')).to eq true
    end

    it 'returns false if the state does not match the performer' do
      configuration = GoodJob::Configuration.new({ queues: 'mice:2' })
      scheduler = described_class.from_configuration(configuration)

      expect(scheduler.create_thread(queue_name: 'elephant')).to eq false
    end
  end

  describe '.from_configuration' do
    describe 'multi-scheduling' do
      it 'instantiates multiple schedulers' do
        configuration = GoodJob::Configuration.new({ queues: '*:1;mice,ferrets:2;elephant:4' })
        multi_scheduler = described_class.from_configuration(configuration)

        all_scheduler, rodents_scheduler, elephants_scheduler = multi_scheduler.schedulers

        expect(all_scheduler.instance_variable_get(:@performer).name).to eq '*'
        expect(all_scheduler.instance_variable_get(:@pool_options)[:max_threads]).to eq 1

        expect(rodents_scheduler.instance_variable_get(:@performer).name).to eq 'mice,ferrets'
        expect(rodents_scheduler.instance_variable_get(:@pool_options)[:max_threads]).to eq 2

        expect(elephants_scheduler.instance_variable_get(:@performer).name).to eq 'elephant'
        expect(elephants_scheduler.instance_variable_get(:@pool_options)[:max_threads]).to eq 4
      end
    end
  end
end
