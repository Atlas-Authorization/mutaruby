# frozen_string_literal: true

require_relative '../test_helper'

class RunnerTest < Minitest::Test
  include TestHelpers

  LIB = { 'lib/a.rb' => "# é\nX = 1 + 2\n" }.freeze

  def run_on(root, command, **kw)
    Mutaruby::Runner.new(options(root: root, command: command, **kw), out: StringIO.new).run
  end

  def statuses(report)
    report.outcomes.to_h { |o| [o.mutation.change, o.status] }
  end

  # Regression: the unmutated code must pass first, or every mutant would be "killed" and the score meaningless.
  def test_baseline_must_pass
    with_project(LIB) do |root|
      err = assert_raises(Mutaruby::BaselineFailed) { run_on(root, 'echo broken-suite; exit 1') }
      assert_match(/fails on the UNMUTATED code \(exit 1\)/, err.message)
      assert_match(/broken-suite/, err.message)
    end
  end

  def test_verdicts_follow_the_exit_status
    with_project(LIB) do |root|
      r = run_on(root, "! grep -q '1 - 2' lib/a.rb")
      st = statuses(r)
      assert_equal :killed, st['+ => -']
      assert_equal :survived, st['1 => 0']
      assert_equal 1, r.killed
      assert_equal r.outcomes.size - 1, r.count(:survived)
      assert_in_delta 100.0 / r.outcomes.size, r.score, 0.001
      assert_equal r.outcomes.map { |o| o.mutation.id }.sort, r.outcomes.map { |o| o.mutation.id }
      assert_equal ['lib/a.rb'], r.files
      assert r.complete
      assert_operator r.timeout, :>=, 5
      assert_operator r.timeout, :<=, 10
      assert_equal 2, r.jobs
    end
  end

  # Regression: every mutant runs in a fresh process (a new shell per run), so nothing loaded by one run (a required
  # file, a monkey patch, a global) can hide the next mutant.
  def test_every_run_is_a_fresh_process
    with_project(LIB) do |root|
      Dir.mktmpdir do |log|
        r = run_on(root, "echo \"$$ ${MUTARUBY_MUTANT_ID:-base}\" >> #{log}/pids; exit 0", jobs: 3)
        lines = File.readlines(File.join(log, 'pids')).map(&:split)
        assert_equal r.outcomes.size + 1, lines.size
        assert_equal lines.size, lines.map(&:first).uniq.size
        assert_equal ['base'] + r.outcomes.map { |o| o.mutation.id.to_s }.sort, lines.map(&:last).sort_by { |x| x == 'base' ? -1 : x.to_i }
      end
    end
  end

  # Regression: the user's files are never written, whatever the test command does.
  def test_original_files_are_never_touched
    with_project(LIB.merge('test/t.sh' => "echo junk >> lib/a.rb\nexit 1\n")) do |root|
      before = snapshot(root)
      err = assert_raises(Mutaruby::BaselineFailed) { run_on(root, 'sh test/t.sh') }
      assert err
      run_on(root, "grep -q '1 + 2' lib/a.rb && echo x >> lib/a.rb")
      assert_equal before, snapshot(root)
      assert_empty Dir.glob(File.join(root, '**', '*mutaruby*'))
    end
  end

  def test_timeouts_are_kills_reported_separately
    with_project(LIB) do |root|
      r = run_on(root, "if grep -q '1 - 2' lib/a.rb; then sleep 30; fi; exit 0", timeout: 0.3)
      assert_equal :timeout, statuses(r)['+ => -']
      assert_equal 1, r.count(:timeout)
      assert_equal 1, r.killed
      assert r.outcomes.find { |o| o.status == :timeout }.killed?
      assert_in_delta 0.3, r.timeout
    end
  end

  def test_ignore_file_marks_equivalents_and_reports_stale_entries
    ign = <<~YAML
      - file: lib/a.rb
        operator: literal-int
        line: "X = 1 + 2"
        mutation: "1 => 0"
        reason: "pretend this is equivalent"
      - file: lib/a.rb
        operator: arithmetic
        line: "X = 1 + 2"
        reason: "wrong: this one is killed"
    YAML
    with_project(LIB.merge('.mutaruby-ignore.yml' => ign)) do |root|
      r = run_on(root, "! grep -q '1 - 2' lib/a.rb")
      assert_equal :equivalent, statuses(r)['1 => 0']
      assert_equal :killed, statuses(r)['+ => -']
      assert_equal 1, r.count(:equivalent)
      assert_equal ['arithmetic'], r.stale.map(&:operator)
      assert_in_delta 100.0 / (r.outcomes.size - 1), r.score, 0.001
      partial = run_on(root, "! grep -q '1 - 2' lib/a.rb", shard: [1, 2])
      assert_empty partial.stale
      refute partial.complete
    end
  end

  def test_explicit_ignore_file_and_errors
    with_project(LIB.merge('ign.yml' => "- file: lib/a.rb\n  operator: arithmetic\n  line: nope\n  reason: r\n")) do |root|
      err = assert_raises(Mutaruby::Error) { run_on(root, 'true', ignore_file: File.join(root, 'ign.yml')) }
      assert_match(/STALE/, err.message)
      assert_raises(Mutaruby::Error) { run_on(root, 'true', ignore_file: File.join(root, 'missing.yml')) }
    end
  end

  def test_plan_applies_filters_and_reports_parse_errors
    with_project(LIB.merge('lib/bad.rb' => "def (\n")) do |root|
      runner = Mutaruby::Runner.new(options(root: root, command: 'true', operators: ['arithmetic']), out: StringIO.new)
      plan = runner.plan
      assert_equal ['lib/a.rb', 'lib/bad.rb'], plan[:files]
      assert_equal ['+ => -'], plan[:mutations].map(&:change)
      refute plan[:complete]
      r = runner.run
      assert_match(/lib\/bad\.rb: cannot parse/, r.warnings.join)
    end
  end

  def test_progress_marks
    with_project(LIB) do |root|
      out = StringIO.new
      Mutaruby::Runner.new(options(root: root, command: "! grep -q '1 - 2' lib/a.rb", progress: true, jobs: 1), out: out).run
      assert_match(/\A[.S]+\n\z/, out.string)
      assert_includes out.string, '.'
    end
  end

  def test_empty_selection
    with_project(LIB) do |root|
      r = run_on(root, 'true', patterns: ['nothing.rb'])
      assert_empty r.outcomes
      assert_nil r.score
    end
  end
end
