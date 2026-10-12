# frozen_string_literal: true

require 'rbconfig'

ruby = RbConfig.ruby

namespace :test do
  desc 'Fast unit tests (also the oracle for `rake mutate`)'
  task(:unit) { sh ruby, '-Ilib', '-Itest', 'test/run_unit.rb' }

  desc 'End-to-end: the CLI against test/fixtures/calc'
  task(:e2e) { sh ruby, '-Ilib', '-Itest', '-e', 'Dir["test/e2e/*_test.rb"].sort.each { |f| require "./#{f}" }' }
end

desc 'All tests'
task test: %w[test:unit test:e2e]

desc 'Run mutaruby on its own code, with the unit tests as the oracle'
task :mutate do
  sh ruby, 'exe/mutaruby', '-t', "#{ruby} -Ilib -Itest test/run_unit.rb", '--json', 'mutaruby-self.json'
end

task default: :test
