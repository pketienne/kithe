require 'shrine'

module Kithe
  class Engine < ::Rails::Engine
    config.generators do |g|
      g.test_framework :rspec, :fixture => false
      g.fixture_replacement :factory_bot, :dir => 'spec/factories'
      g.assets false
      g.helper false
    end

    # should only affect kithe development
    config.active_record.schema_format = :sql
  end
end
