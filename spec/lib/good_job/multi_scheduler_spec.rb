require 'rails_helper'

RSpec.describe GoodJob::MultiScheduler do
  describe '#create_thread' do
    let(:multi_scheduler) { described_class.new([scheduler_1, scheduler_2]) }
    let(:scheduler_1) { instance_double(GoodJob::Scheduler, create_thread: nil) }
    let(:scheduler_2) { instance_double(GoodJob::Scheduler, create_thread: nil) }

    it 'delegates to all schedulers if they return nil' do
      state = { key: 'value' }
      result = multi_scheduler.create_thread(state)
      expect(result).to eq nil

      expect(scheduler_1).to have_received(:create_thread).with(state)
      expect(scheduler_2).to have_received(:create_thread).with(state)
    end

    it 'delegates to all schedulers if they return false' do
      allow(scheduler_1).to receive(:create_thread).and_return(false)
      allow(scheduler_2).to receive(:create_thread).and_return(false)

      result = multi_scheduler.create_thread
      expect(result).to eq false

      expect(scheduler_1).to have_received(:create_thread)
      expect(scheduler_2).to have_received(:create_thread)
    end

    it 'delegates to each schedulers until one of them returns true' do
      allow(scheduler_1).to receive(:create_thread).and_return(true)
      allow(scheduler_2).to receive(:create_thread).and_return(false)

      result = multi_scheduler.create_thread
      expect(result).to eq true

      expect(scheduler_1).to have_received(:create_thread)
      expect(scheduler_2).not_to have_received(:create_thread)
    end
  end
end
