# frozen_string_literal: true

require 'rbconfig'

ruby = RbConfig.ruby

namespace :test do
  desc 'Unit tests'
  task(:unit) { sh ruby, '-Ilib', '-Itest', 'test/run_unit.rb' }

  desc 'End-to-end: the CLI against test/fixtures/calc'
  task(:e2e) { sh ruby, '-Ilib', '-Itest', '-e', 'Dir["test/e2e/*_test.rb"].sort.each { |f| require "./#{f}" }' }
end

desc 'All tests'
task test: %w[test:unit test:e2e]

desc 'Run mutaruby on its own code (oracle: test/dogfood.rb); fails below 100% or on a stale ignore entry'
task :mutate do
  sh ruby, 'exe/mutaruby', '-t', "#{ruby} -Ilib -Itest test/dogfood.rb", '--fail-under', '100', '--strict-ignore',
     '--json', 'mutaruby-self.json'
end

task default: :test
