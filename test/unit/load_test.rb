# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'

# Every file of the library loads on its own in a fresh Ruby (it requires what it uses) and works.
class LoadTest < Minitest::Test
  LIB = File.expand_path('../../lib', __dir__)

  SMOKE = {
    'mutaruby' => 'Mutaruby::CLI.new(["--version"]).run',
    'mutaruby/version' => 'raise unless Mutaruby::VERSION.match?(/\A\d+\.\d+\.\d+\z/)',
    'mutaruby/error' => 'raise unless Mutaruby::Error.ancestors.include?(StandardError)',
    'mutaruby/parsing' => 'raise unless Mutaruby::Parsing.valid?("x", "1 + 1") && Parser::AST::Node; begin; Mutaruby::Parsing.grammar_for("1.0"); raise "no"; rescue Mutaruby::Error; end',
    'mutaruby/splicer' => 'raise unless Mutaruby::Splicer.splice("ab", 1, 2, "b", "c") == "ac"',
    'mutaruby/mutation' => 'raise unless Mutaruby::Mutation.new(operator: "o", orig: "a", repl: "b").label == "o: a => b"',
    'mutaruby/generator' => 'raise unless Mutaruby::Generator.new("a + b", path: "x").mutations.any?',
    'mutaruby/ignore_file' => 'f = File.join(ARGV[0], "i.yml"); File.write(f, "- file: a\n  operator: comparison\n  line: x\n  reason: r\n"); raise unless Mutaruby::IgnoreFile.load(f).entries.size == 1',
    'mutaruby/sandbox' => 'File.write(File.join(ARGV[0], "f"), "1"); b = Mutaruby::Sandbox.new(ARGV[0]); raise unless File.read(b.path("f")) == "1"; b.cleanup',
    'mutaruby/command' => 'd = ARGV[0]; c = %("#{RbConfig.ruby}" -e "puts 1"); raise unless Mutaruby::Command.new(c, root: d).run(d, capture: true).output == "1\n"',
    'mutaruby/selection' => 's = Mutaruby::Selection.new(root: ARGV[0]); raise unless s.files == [] && s.send(:git, "--version").first.start_with?("git"); begin; Mutaruby::Selection.parse_shard("x"); raise; rescue Mutaruby::Error; end',
    'mutaruby/runner' => 'd = ARGV[0]; Dir.mkdir(File.join(d, "lib")); File.write(File.join(d, "lib/a.rb"), "X = 1\n"); r = Mutaruby::Runner.new(Mutaruby::Runner::Options.build(root: d, command: %("#{RbConfig.ruby}" -e 0), operators: ["literal-int"]), out: StringIO.new).run; raise unless r.outcomes.size == 2',
    'mutaruby/platform' => 'raise unless [true, false].include?(Mutaruby::Platform.windows?) && Mutaruby::Platform.current.spawn_options.size == 1',
    'mutaruby/coverage_map' => 'raise unless Mutaruby::CoverageMap.new({ "framework" => "x", "tests" => { "t" => { "f" => [1] } }, "load" => {} }).tests_for("f", [1]) == ["t"] && Mutaruby::CoverageMap.probe_env({}).size == 2',
    'mutaruby/render' => 'raise unless Mutaruby::Render.unparse("[1, 2]", 0) == "[2]" && Mutaruby::Render::Unavailable.ancestors.include?(Mutaruby::Error)',
    'mutaruby/probe/mutaruby_probe' => 'raise unless MutarubyProbe.respond_to?(:setup) && !Object.ancestors.include?(MutarubyProbe::RequireHook)',
    'mutaruby/reporters' => 'r = Struct.new(:outcomes, :command, :score, :complete, :files, :baseline_seconds, :timeout, :stale, :warnings, :killed, :seconds, :coverage) { def count(*) = 0 }.new([], "c", nil, true, [], 1.0, 2, [], [], 0, 1.0, nil); io = StringIO.new; Mutaruby::Reporters.json(r, io); Mutaruby::Reporters.junit(r, io); raise unless io.string.include?("tests=\"0\"") && Mutaruby::Reporters.esc("<") == "&lt;"',
    'mutaruby/cli' => 'raise unless Mutaruby::CLI.new(["--list-operators"], stdout: StringIO.new).run.zero? && Mutaruby::CLI.new([]).options.jobs == Etc.nprocessors'
  }.freeze

  # Files that need no gem: loaded with --disable-gems, so a missing require of a default library (rbconfig, which
  # RubyGems would otherwise have loaded) shows.
  NO_GEMS = %w[mutaruby/version mutaruby/error mutaruby/splicer mutaruby/mutation mutaruby/platform mutaruby/sandbox
               mutaruby/command mutaruby/selection mutaruby/reporters mutaruby/coverage_map
               mutaruby/probe/mutaruby_probe].freeze

  def test_every_library_file_is_covered
    files = Dir[File.join(LIB, '**/*.rb')].map { |f| f.delete_prefix("#{LIB}/").delete_suffix('.rb') }.sort
    assert_equal files, SMOKE.keys.sort
  end

  def test_each_file_loads_alone
    results = SMOKE.map do |feature, code|
      Thread.new do
        Dir.mktmpdir do |dir|
          script = "require 'stringio'\nrequire #{feature.inspect}\n#{code}\n"
          # gem-free files run without RubyGems and without RUBYOPT (under bundle exec it would load Bundler, and with
          # it RbConfig and the gemspec's mutaruby/version)
          plain = NO_GEMS.include?(feature)
          out, st = Open3.capture2e(plain ? { 'RUBYOPT' => nil } : {}, RbConfig.ruby, *(plain ? ['--disable-gems'] : []),
                                    '-I', LIB, '-e', script, '--', File.realpath(dir), stdin_data: '')
          [feature, st.success?, out]
        end
      end
    end.map(&:value)
    failed = results.reject { |_, ok, _| ok }
    assert_empty failed.map { |f, _, out| "#{f}: #{out.lines.first(3).join}" }
  end
end
