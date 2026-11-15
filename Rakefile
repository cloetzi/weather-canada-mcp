# frozen_string_literal: true

require "minitest/test_task"
require "rubocop/rake_task"

Minitest::TestTask.create(:test) do |task|
  task.test_globs = ["test/**/*_test.rb"]
  task.warning = false
end

RuboCop::RakeTask.new

namespace :gazetteer do
  desc "Download NRCan's Canadian Geographical Names and build the place-name database (WEATHER_MCP_GAZETTEER_PATH)"
  task :build do
    ruby "bin/weather-canada-mcp", "gazetteer", "update"
  end
end

task default: %i[rubocop test]
