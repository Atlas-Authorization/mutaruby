# frozen_string_literal: true

# The oracle for running mutaruby on itself (`rake mutate`): the unit tests that exercise the mutated file, or every
# unit test when no mutant is active (the baseline) or the file is not listed. MUTARUBY_FILE is set by mutaruby.
TESTS = {
  'lib/mutaruby/generator.rb' => %w[generator splicer mutation parsing ignore_file selection reporters render],
  'lib/mutaruby/splicer.rb' => %w[splicer generator cli],
  'lib/mutaruby/mutation.rb' => %w[mutation generator ignore_file reporters],
  'lib/mutaruby/parsing.rb' => %w[parsing generator],
  'lib/mutaruby/ignore_file.rb' => %w[ignore_file runner cli],
  'lib/mutaruby/selection.rb' => %w[selection runner cli],
  'lib/mutaruby/sandbox.rb' => %w[sandbox runner],
  'lib/mutaruby/command.rb' => %w[command runner],
  'lib/mutaruby/platform.rb' => %w[platform command sandbox],
  'lib/mutaruby/coverage_map.rb' => %w[coverage_map runner probe],
  'lib/mutaruby/probe/mutaruby_probe.rb' => %w[probe runner],
  'lib/mutaruby/render.rb' => %w[render generator],
  'lib/mutaruby/runner.rb' => %w[runner cli],
  'lib/mutaruby/reporters.rb' => %w[reporters cli],
  'lib/mutaruby/cli.rb' => %w[cli]
}.freeze
ALWAYS = %w[load constants].freeze

names = TESTS[ENV.fetch('MUTARUBY_FILE', '')]
files = names ? (names + ALWAYS).map { |n| File.join(__dir__, 'unit', "#{n}_test.rb") } : Dir[File.join(__dir__, 'unit', '*_test.rb')]
files.sort.each { |f| require f }
