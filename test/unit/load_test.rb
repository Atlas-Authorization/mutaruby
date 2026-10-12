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
    'mutaruby/command' => 'd = ARGV[0]; raise unless Mutaruby::Command.new("echo hi", root: d).run(d, capture: true).output == "hi\n"',
    'mutaruby/selection' => 's = Mutaruby::Selection.new(root: ARGV[0]); raise unless s.files == [] && s.send(:git, "--version").first.start_with?("git"); begin; Mutaruby::Selection.parse_shard("x"); raise; rescue Mutaruby::Error; end',
    'mutaruby/runner' => 'd = ARGV[0]; Dir.mkdir(File.join(d, "lib")); File.write(File.join(d, "lib/a.rb"), "X = 1\n"); r = Mutaruby::Runner.new(Mutaruby::Runner::Options.build(root: d, command: "true", operators: ["literal-int"]), out: StringIO.new).run; raise unless r.outcomes.size == 2',
    'mutaruby/reporters' => 'r = Struct.new(:outcomes, :command, :score, :complete, :files, :baseline_seconds, :timeout, :stale, :warnings, :killed, :seconds) { def count(*) = 0 }.new([], "c", nil, true, [], 1.0, 2, [], [], 0, 1.0); io = StringIO.new; Mutaruby::Reporters.json(r, io); Mutaruby::Reporters.junit(r, io); raise unless io.string.include?("tests=\"0\"") && Mutaruby::Reporters.esc("<") == "&lt;"',
    'mutaruby/cli' => 'raise unless Mutaruby::CLI.new(["--list-operators"], stdout: StringIO.new).run.zero? && Mutaruby::CLI.new([]).options.jobs == Etc.nprocessors'
  }.freeze

  def test_every_library_file_is_covered
    files = Dir[File.join(LIB, '**/*.rb')].map { |f| f.delete_prefix("#{LIB}/").delete_suffix('.rb') }.sort
    assert_equal files, SMOKE.keys.sort
  end

  def test_each_file_loads_alone
    results = SMOKE.map do |feature, code|
      Thread.new do
        Dir.mktmpdir do |dir|
          script = "require 'stringio'\nrequire #{feature.inspect}\n#{code}\n"
          out, st = Open3.capture2e(RbConfig.ruby, '-I', LIB, '-e', script, '--', File.realpath(dir), stdin_data: '')
          [feature, st.success?, out]
        end
      end
    end.map(&:value)
    failed = results.reject { |_, ok, _| ok }
    assert_empty failed.map { |f, _, out| "#{f}: #{out.lines.first(3).join}" }
  end
end
