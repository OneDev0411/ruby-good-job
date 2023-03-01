# frozen_string_literal: true
require 'rails_helper'

describe GoodJob::FrontendsController do
  describe '#static' do
    it 'returns a file when it matches' do
      get good_job.frontend_static_path(:bootstrap, format: :js, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:ok)

      get good_job.frontend_static_path(:bootstrap, format: :css, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:ok)
    end

    it 'returns a 404 when it does not match' do
      get good_job.frontend_static_path(:yowza, format: :js, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:not_found)

      get good_job.frontend_static_path(:bootstrap, format: :yowza, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:not_found)

      get good_job.frontend_static_path(:rails_ujs, format: :css, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe '#module' do
    it 'returns a file when it matches' do
      get good_job.frontend_module_path(:application, format: :js, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:ok)
    end

    it 'returns a 404 when it does not match' do
      get good_job.frontend_module_path(:yowza, format: :js, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:not_found)

      get good_job.frontend_module_path(:application, format: :yowza, v: GoodJob::VERSION, locale: nil)
      expect(response).to have_http_status(:not_found)
    end
  end
end
