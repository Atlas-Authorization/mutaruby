# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'etc'

class CLITest < Minitest::Test
  include TestHelpers

  GOLDEN = File.expand_path('../golden', __dir__)
  def killer = kill_if('1 - 2')
  def ok = rb('exit 0')

  def cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = Mutaruby::CLI.new(args, stdout: out, stderr: err).run
    [code, out.string, err.string]
  end

  def parsed(*args) = Mutaruby::CLI.new(args).parse

  def test_exit_codes
    assert_equal [0, 1, 2, 130], [Mutaruby::CLI::EXIT_OK, Mutaruby::CLI::EXIT_FAIL, Mutaruby::CLI::EXIT_ERROR,
                                  Mutaruby::CLI::EXIT_INTERRUPTED]
  end

  def test_version
    assert_equal [0, "mutaruby #{Mutaruby::VERSION}\n", ''], cli('--version')
    assert_match(/\A\d+\.\d+\.\d+\z/, Mutaruby::VERSION)
  end

  def test_help_is_exactly_the_documented_text
    want = File.read(File.join(GOLDEN, 'help.txt')).sub('NPROC', Etc.nprocessors.to_s)
    assert_equal [0, want, ''], cli('--help')
    assert_equal [0, want, ''], cli('-h')
  end

  def test_list_operators_is_exactly_the_documented_text
    assert_equal [0, File.read(File.join(GOLDEN, 'operators.txt')), ''], cli('--list-operators')
    assert_equal Mutaruby::Generator::OPERATORS.size, File.readlines(File.join(GOLDEN, 'operators.txt')).size
  end

  def test_defaults
    c = parsed
    o = c.options
    assert_equal [Etc.nprocessors, true, '.', [], nil, nil, 3.0], [o.jobs, o.progress, o.root, o.patterns, o.command,
                                                                    o.operators, o.timeout_factor]
    assert_equal({}, c.flags)
  end

  def test_every_option_is_parsed
    args = %w[-t rake -C proj -j 3 --timeout 1.5 --timeout-factor 2 --copy-exclude tmp --copy-exclude log --since main
              --method A#b --method c --exclude-method d --line a.rb:1-2 --line 9 --exclude-line b.rb:4 --shard 2/5
              --ignore-file i.yml --strict-ignore --suggest-ignore --json r.json --junit r.xml --fail-under 80
              --list -q -v lib/x.rb lib/y.rb]
    c = parsed(*args)
    o = c.options
    assert_equal ['rake', 'proj', 3, 1.5, 2.0, %w[tmp log], 'main', %w[A#b c], %w[d], [2, 5], 'i.yml', false,
                  %w[lib/x.rb lib/y.rb]],
                 [o.command, o.root, o.jobs, o.timeout, o.timeout_factor, o.copy_excludes, o.since, o.methods,
                  o.exclude_methods, o.shard, o.ignore_file, o.progress, o.patterns]
    assert_kind_of Float, o.timeout
    assert_kind_of Float, o.timeout_factor
    assert_equal [['a.rb', 1, 2], [nil, 9, 9]], o.lines.map(&:to_a)
    assert_equal [['b.rb', 4, 4]], o.exclude_lines.map(&:to_a)
    assert_equal({ strict: true, suggest: true, json: 'r.json', junit: 'r.xml', fail_under: 80.0, list: true,
                   verbose: true }, c.flags)
    assert_equal false, parsed('--quiet').options.progress
    assert_equal({ list_operators: true }, parsed('--list-operators').flags)
    assert_equal 'x', parsed('--root', 'x').options.root
    assert_equal 'c', parsed('--test', 'c').options.command
    assert_equal 4, parsed('--jobs', '4').options.jobs
    assert_equal({ verbose: true }, parsed('--verbose').flags)
  end

  def test_the_arguments_are_not_modified
    args = %w[--list-operators lib/a.rb].freeze
    assert_equal 0, Mutaruby::CLI.new(args, stdout: StringIO.new).run
  end

  def test_operator_selection
    all = Mutaruby::Generator::OPERATORS.keys
    assert_nil parsed.options.operators
    assert_equal %w[arithmetic], parsed('--operators', 'arith*').options.operators
    assert_equal %w[comparison condition-negate condition-true condition-false],
                 parsed('--operators', 'condition-*', '--operators', 'comparison').options.operators
    assert_equal all - %w[literal-int], parsed('--exclude-operators', 'literal-int').options.operators
    assert_equal %w[condition-true], parsed('--operators', 'condition-*', '--exclude-operators', 'condition-negate,condition-false').options.operators
  end

  def test_usage_errors_exit_2
    assert_equal [2, '', "mutaruby: missing --test COMMAND (the command that runs your tests; exit 0 = pass)\n"], cli
    assert_equal [2, '', "mutaruby: unknown operator \"nope\" (see --list-operators)\n"], cli('-t', 'true', '--operators', 'nope')
    assert_equal [2, '', "mutaruby: unknown operator \"zz*\" (see --list-operators)\n"], cli('-t', 'true', '--exclude-operators', 'zz*')
    assert_equal [2, '', "mutaruby: invalid option: --bogus\n"], cli('--bogus')
    assert_equal [2, '', "mutaruby: bad --shard \"3/2\" (expected I/N, 1 <= I <= N)\n"], cli('-t', 'x', '--shard', '3/2')
    assert_equal 2, cli('-t', 'x', '--line', 'a:b').first
    assert_equal [2, '', "mutaruby: invalid argument: --jobs x\n"], cli('--jobs', 'x')
  end

  def test_list_mutants
    with_project('lib/a.rb' => "class K\n  def f = 1 + 2\nend\nX = 3 - 4\n") do |root|
      code, out, err = cli('--list', '-C', root, '--operators', 'arith*')
      assert_equal 0, code
      assert_equal "0\tlib/a.rb:2\tK#f\tarithmetic: + => -\n1\tlib/a.rb:4\t-\tarithmetic: - => +\n", out
      assert_equal "2 mutants in 1 files\n", err
    end
  end

  def test_full_run_writes_reports_and_applies_fail_under
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      json = File.join(root, '..', 'out.json')
      xml = File.join(root, '..', 'out.xml')
      code, out, err = cli('-C', root, '-t', killer, '-q', '-j', '2', '--json', json, '--junit', xml,
                           '--fail-under', '50', '--suggest-ignore')
      assert_equal 1, code
      assert out.start_with?('Surviving mutants (not detected by the test command):')
      assert_includes out, "mutaruby summary\n"
      lines = err.lines
      assert_equal 'mutaruby: score 16.67% is below --fail-under 50.00%', lines.last.chomp
      assert_equal "# ignore-file stubs (add a reason to each; keep only true equivalents):\n", lines.first
      stubs = YAML.safe_load(lines[1...-1].join)
      assert_equal 5, stubs.size
      assert_equal %w[literal-int], stubs.map { |h| h['operator'] }.uniq
      assert_equal 1, JSON.parse(File.read(json))['counts']['killed']
      assert File.read(xml).start_with?('<?xml')
      assert_equal [0, ''], cli('-C', root, '-t', killer, '-q', '--fail-under', '16.6').values_at(0, 2)
      assert_equal 1, cli('-C', root, '-t', killer, '-q', '--fail-under', '16.7').first
      assert_equal [0, ''], cli('-C', root, '-t', killer, '-q').values_at(0, 2)
    end
  end

  def test_score_equal_to_fail_under_passes
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      code, _, err = cli('-C', root, '-t', rb('exit 1'), '--operators', 'literal-int', '-q', '--fail-under', '100')
      assert_equal [2, true], [code, err.include?('UNMUTATED')]
      code, _, err = cli('-C', root, '-t', killer, '--operators', 'arithmetic', '-q',
                         '--fail-under', '100')
      assert_equal [0, ''], [code, err]
    end
  end

  def test_no_mutants_never_fails_the_score
    with_project('lib/a.rb' => "X = 1\n") do |root|
      assert_equal [0, ''], cli('-C', root, '-t', ok, '-q', '--fail-under', '50', 'nothing.rb').values_at(0, 2)
    end
  end

  def test_suggest_without_survivors_prints_nothing
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      code, _, err = cli('-C', root, '-t', killer, '-q', '--operators', 'arithmetic', '--suggest-ignore')
      assert_equal [0, ''], [code, err]
    end
  end

  def test_progress_goes_to_stderr
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      _, _, err = cli('-C', root, '-t', killer, '-j', '1', '--operators', 'arithmetic')
      assert_equal ".\n", err
    end
  end

  def test_verbose_lists_timeouts
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      cmd = rb('sleep 30 if File.read("lib/a.rb").include?("1 - 2")')
      _, out, = cli('-C', root, '-t', cmd, '-q', '--operators', 'arithmetic', '--timeout', '1', '-v')
      assert_includes out, "  timeout: lib/a.rb:1 arithmetic: + => -\n"
      _, out, = cli('-C', root, '-t', cmd, '-q', '--operators', 'arithmetic', '--timeout', '1')
      refute_includes out, 'timeout: lib'
    end
  end

  def test_json_to_stdout_moves_the_summary_to_stderr
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      code, out, err = cli('-C', root, '-t', ok, '-q', '--json', '-', '--operators', 'arithmetic')
      assert_equal 0, code
      assert_equal 1, JSON.parse(out)['counts']['survived']
      assert err.start_with?('Surviving mutants')
      code, out, err = cli('-C', root, '-t', ok, '-q', '--junit', '-', '--operators', 'arithmetic')
      assert_equal 0, code
      assert out.start_with?('<?xml')
      assert err.start_with?('Surviving mutants')
      _, out, err = cli('-C', root, '-t', ok, '-q', '--operators', 'arithmetic')
      assert out.start_with?('Surviving mutants')
      assert_equal '', err
    end
  end

  def test_baseline_failure_exits_2
    with_project('lib/a.rb' => "X = 1\n") do |root|
      code, out, err = cli('-C', root, '-t', rb('exit 4'), '-q')
      assert_equal [2, ''], [code, out]
      assert err.start_with?('mutaruby: the test command fails on the UNMUTATED code (exit 4)')
    end
  end

  def test_strict_ignore
    ign = "- file: lib/a.rb\n  operator: arithmetic\n  line: X = 1 + 2\n  reason: was equivalent once\n" \
          "- file: lib/a.rb\n  operator: arithmetic\n  line: Y = 3 + 4\n  reason: this one too\n"
    with_project('lib/a.rb' => "X = 1 + 2\nY = 3 + 4\n", '.mutaruby-ignore.yml' => ign) do |root|
      cmd = kill_if(' - ')
      code, out, err = cli('-C', root, '-t', cmd, '-q')
      assert_equal 0, code, err
      assert_includes out, 'STALE ignore entry'
      assert_equal '', err
      assert_equal [0, ''], cli('-C', root, '-t', cmd, '-q', '--operators', 'arithmetic', '--strict-ignore').values_at(0, 2)
      code, _, err = cli('-C', root, '-t', cmd, '-q', '--strict-ignore')
      assert_equal [1, "mutaruby: 2 stale ignore entries (--strict-ignore)\n"], [code, err]
      File.write(File.join(root, '.mutaruby-ignore.yml'), ign.lines.first(4).join)
      code, _, err = cli('-C', root, '-t', cmd, '-q', '--strict-ignore')
      assert_equal [1, "mutaruby: 1 stale ignore entry (--strict-ignore)\n"], [code, err]
      bad = File.join(root, 'bad.yml')
      File.write(bad, "- nope\n")
      assert_equal [2, '', "mutaruby: #{bad}: entry #1: expected a mapping\n"], cli('-C', root, '-t', cmd, '--ignore-file', bad)
    end
  end

  def test_splice_errors_exit_2
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      Mutaruby::Splicer.singleton_class.alias_method(:real_splice, :splice)
      Mutaruby::Splicer.define_singleton_method(:splice) { |*| raise Mutaruby::SpliceError, 'boom' }
      begin
        assert_equal [2, '', "mutaruby: boom\n"], cli('-C', root, '-t', ok, '--list')
      ensure
        Mutaruby::Splicer.singleton_class.alias_method(:splice, :real_splice)
      end
    end
  end

  # Ctrl-C: in-flight runs are killed and the exit status is 130.
  def test_interrupt
    posix_only! # signals to another process
    with_project('lib/a.rb' => "X = 1 + 2\n") do |root|
      cmd = '[ "$MUTARUBY_MUTANT_ID" = 0 ] && kill -INT $PPID; sleep 0.2'
      code, _, err = cli('-C', root, '-t', cmd, '-q', '-j', '1')
      assert_equal [130, "\nmutaruby: interrupted\n"], [code, err]
    end
  end
end
