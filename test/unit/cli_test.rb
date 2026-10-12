# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

class CLITest < Minitest::Test
  include TestHelpers

  def cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = Mutaruby::CLI.new(args, stdout: out, stderr: err).run
    [code, out.string, err.string]
  end

  def test_version_and_help
    assert_equal [0, "mutaruby #{Mutaruby::VERSION}\n", ''], cli('--version')
    code, out, = cli('--help')
    assert_equal 0, code
    %w[--test --jobs --timeout --since --method --line --shard --ignore-file --json --junit --fail-under].each do |opt|
      assert_includes out, opt
    end
  end

  def test_list_operators
    code, out, = cli('--list-operators')
    assert_equal 0, code
    assert_equal Mutaruby::Generator::OPERATORS.size, out.lines.size
    assert_match(/^arithmetic +swap/, out)
  end

  def test_usage_errors_exit_2
    assert_equal 2, cli.first
    code, _, err = cli('-t', 'true', '--operators', 'nope')
    assert_equal 2, code
    assert_match(/unknown operator "nope"/, err)
    assert_equal 2, cli('--bogus').first
    assert_equal 2, cli('-t', 'x', '--shard', '3/2').first
    assert_equal 2, cli('-t', 'x', '--line', 'a:b').first
  end

  def test_list_mutants
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      code, out, err = cli('--list', '-C', root, '--operators', 'arith*,literal-int', '--exclude-operators', 'literal-int')
      assert_equal 0, code
      assert_equal "0\tlib/a.rb:1\t-\tarithmetic: + => -\n", out
      assert_match(/1 mutants in 1 files/, err)
    end
  end

  def test_full_run_writes_reports_and_applies_fail_under
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      json = File.join(root, '..', 'out.json')
      xml = File.join(root, '..', 'out.xml')
      code, out, err = cli('-C', root, '-t', "! grep -q '1 - 2' lib/a.rb", '-q', '-j', '2', '--json', json,
                           '--junit', xml, '--fail-under', '50', '--suggest-ignore', '-v')
      assert_equal 1, code
      assert_match(/mutaruby summary/, out)
      assert_match(/below --fail-under 50\.00%/, err)
      assert_match(/ignore-file stubs/, err)
      assert_match(/operator: literal-int/, err)
      j = JSON.parse(File.read(json))
      assert_equal 1, j['counts']['killed']
      assert_match(/<testsuites/, File.read(xml))
      assert_equal 0, cli('-C', root, '-t', "! grep -q '1 - 2' lib/a.rb", '-q', '--fail-under', '10').first
      assert_equal 0, cli('-C', root, '-t', "! grep -q '1 - 2' lib/a.rb", '-q').first
    end
  end

  def test_json_to_stdout_moves_the_summary_to_stderr
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      code, out, err = cli('-C', root, '-t', 'exit 0', '-q', '--json', '-', '--operators', 'arithmetic')
      assert_equal 0, code
      assert_equal 1, JSON.parse(out)['counts']['survived']
      assert_match(/mutaruby summary/, err)
      code, out, = cli('-C', root, '-t', 'exit 0', '-q', '--junit', '-', '--operators', 'arithmetic')
      assert_equal 0, code
      assert out.start_with?('<?xml')
    end
  end

  def test_baseline_failure_exits_2
    with_project('lib/a.rb' => "X = 1\n") do |root|
      code, _, err = cli('-C', root, '-t', 'exit 4', '-q')
      assert_equal 2, code
      assert_match(/UNMUTATED/, err)
    end
  end

  def test_strict_ignore
    ign = "- file: lib/a.rb\n  operator: arithmetic\n  line: X = 1 + 2\n  reason: was equivalent once\n"
    with_project('lib/a.rb' => "X = 1 + 2\n", '.mutaruby-ignore.yml' => ign) do |root|
      cmd = "! grep -q '1 - 2' lib/a.rb"
      assert_equal 0, cli('-C', root, '-t', cmd, '-q', '--operators', 'arithmetic').first
      code, out, err = cli('-C', root, '-t', cmd, '-q', '--operators', 'arithmetic,literal-int', '--strict-ignore')
      assert_equal 0, code, "an operator-filtered run is not complete, so nothing is stale: #{out}#{err}"
      code, _, err = cli('-C', root, '-t', cmd, '-q', '--strict-ignore')
      assert_equal 1, code
      assert_match(/1 stale ignore entry/, err)
      bad = File.join(root, 'bad.yml')
      File.write(bad, "- nope\n")
      assert_equal 2, cli('-C', root, '-t', cmd, '--ignore-file', bad).first
    end
  end
end
