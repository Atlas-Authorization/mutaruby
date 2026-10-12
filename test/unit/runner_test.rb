# frozen_string_literal: true

require_relative '../test_helper'

class RunnerTest < Minitest::Test
  include TestHelpers

  LIB = { 'lib/a.rb' => "# é\nX = 1 + 2\n" }.freeze
  TWO = { 'lib/a.rb' => "A = 1\n", 'lib/b.rb' => "B = 7\n" }.freeze

  def run_on(root, command, out: StringIO.new, **kw)
    Mutaruby::Runner.new(options(root: root, command: command, **kw), out: out).run
  end

  def statuses(report)
    report.outcomes.to_h { |o| [o.mutation.change, o.status] }
  end

  # Records, per run, what the test command saw: every file of the project and the per-mutant variables.
  def recorder(log)
    "id=${MUTARUBY_MUTANT_ID:-base}; cat lib/*.rb > #{log}/$id.src; echo \"$MUTARUBY_FILE|$MUTARUBY\" > #{log}/$id.env"
  end

  # A private TMPDIR, so the sandboxes a run creates can be counted.
  def with_tmpdir
    Dir.mktmpdir do |t|
      with_env('TMPDIR' => t) { yield t }
    end
  end

  def sandboxes_in(tmp) = Dir.glob(File.join(tmp, 'mutaruby-*'))

  def test_options_defaults
    o = Mutaruby::Runner::Options.build
    assert_equal ['.', [], 1, 3.0, [], [], [], [], [], false],
                 [o.root, o.patterns, o.jobs, o.timeout_factor, o.methods, o.exclude_methods, o.lines, o.exclude_lines,
                  o.copy_excludes, o.progress]
    assert_nil o.timeout
    assert_equal 4, Mutaruby::Runner::Options.build(jobs: 4).jobs
    assert_equal({ killed: '.', timeout: 'T', survived: 'S', equivalent: 'e' }, Mutaruby::Runner::MARK)
  end

  def test_outcome_and_report
    o = ->(st) { Mutaruby::Runner::Outcome.new(status: st) }
    assert_equal [true, true, false, false], %i[killed timeout survived equivalent].map { |s| o.call(s).killed? }
    r = Mutaruby::Runner::Report.new(outcomes: %i[killed timeout survived equivalent equivalent].map { |s| o.call(s) })
    assert_equal [1, 1, 1, 2, 2], [r.count(:killed), r.count(:timeout), r.count(:survived), r.count(:equivalent), r.killed]
    assert_in_delta 66.6667, r.score, 0.001
    assert_nil Mutaruby::Runner::Report.new(outcomes: [o.call(:equivalent)]).score
    assert_in_delta 100.0, Mutaruby::Runner::Report.new(outcomes: [o.call(:killed)]).score
  end

  # Regression: the unmutated code must pass first, or every mutant would be "killed" and the score meaningless.
  def test_baseline_must_pass
    with_tmpdir do |tmp|
      with_project(LIB) do |root|
        err = assert_raises(Mutaruby::BaselineFailed) { run_on(root, 'echo suite-output; exit 3') }
        assert_equal "the test command fails on the UNMUTATED code (exit 3); every mutant would count as killed, so " \
                     "nothing would be measured.\ncommand: echo suite-output; exit 3\n--- output (tail) ---\n" \
                     "suite-output\n", err.message
        assert_kind_of Mutaruby::Error, err
        assert_empty sandboxes_in(tmp)
      end
    end
  end

  # Each mutant's run sees exactly that mutant's text in its file, every other file as the original, and its own
  # variables; the baseline sees the original project.
  def test_each_run_sees_exactly_its_mutant
    Dir.mktmpdir do |log|
      with_project(TWO) do |root|
        r = run_on(root, recorder(log), jobs: 1)
        assert_equal TWO.values.join, File.read(File.join(log, 'base.src'))
        assert_equal "|1\n", File.read(File.join(log, 'base.env'))
        assert_operator r.outcomes.size, :>=, 4
        assert_equal (0...r.outcomes.size).to_a, r.outcomes.map { |o| o.mutation.id }
        assert_equal %w[lib/a.rb lib/b.rb], r.outcomes.map { |o| o.mutation.file }.uniq
        r.outcomes.each do |o|
          m = o.mutation
          want = TWO.map { |f, src| f == m.file ? m.text : src }.join
          assert_equal want, File.read(File.join(log, "#{m.id}.src")), m.label
          assert_equal "#{m.file}|1\n", File.read(File.join(log, "#{m.id}.env"))
        end
      end
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
      assert_equal ['lib/a.rb'], r.files
      assert_equal({ 'lib/a.rb' => LIB['lib/a.rb'] }, r.sources)
      assert r.complete
      assert_equal 2, r.jobs
      assert_equal [], r.stale
      assert_equal [], r.warnings
      assert_equal root, r.root
      assert_equal "! grep -q '1 - 2' lib/a.rb", r.command
      assert_operator r.seconds, :>, 0
      assert_operator r.seconds, :<, 60
      assert_operator r.baseline_seconds, :>, 0
      assert_operator r.seconds, :>, r.baseline_seconds
    end
  end

  def test_relative_root
    with_project(LIB) do |root|
      Dir.chdir(root) do
        r = run_on('.', 'true', operators: ['arithmetic'])
        assert_equal Dir.pwd, r.root
        assert_equal 1, r.outcomes.size
      end
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
        assert_equal ['base'] + r.outcomes.map { |o| o.mutation.id.to_s }, lines.map(&:last).sort_by { |x| x == 'base' ? -1 : x.to_i }
      end
    end
  end

  # Regression: the user's files are never written, whatever the test command does.
  def test_original_files_are_never_touched
    with_project(LIB.merge('test/t.sh' => "echo junk >> lib/a.rb\nexit 1\n")) do |root|
      before = snapshot(root)
      assert_raises(Mutaruby::BaselineFailed) { run_on(root, 'sh test/t.sh') }
      run_on(root, "grep -q '1 + 2' lib/a.rb && echo x >> lib/a.rb")
      assert_equal before, snapshot(root)
    end
  end

  def test_timeouts_are_kills_reported_separately
    with_project(LIB) do |root|
      r = run_on(root, "if grep -q '1 - 2' lib/a.rb; then sleep 30; fi; exit 0", timeout: 0.3)
      assert_equal :timeout, statuses(r)['+ => -']
      assert_equal 1, r.count(:timeout)
      assert_equal 1, r.killed
      assert_in_delta 0.3, r.timeout
    end
  end

  # The default timeout is the baseline time x factor + 5 seconds, rounded up.
  def test_default_timeout_comes_from_the_baseline
    with_project(LIB) do |root|
      r = run_on(root, '[ -n "$MUTARUBY_MUTANT_ID" ] || sleep 0.4', operators: ['arithmetic'], timeout_factor: 2.5)
      assert_operator r.baseline_seconds, :>=, 0.4
      assert_equal ((r.baseline_seconds * 2.5) + 5).ceil, r.timeout
      assert_kind_of Integer, r.timeout
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
      assert_equal 'pretend this is equivalent', r.outcomes.find { |o| o.status == :equivalent }.ignore.reason
      assert_equal :killed, statuses(r)['+ => -']
      assert_equal 1, r.count(:equivalent)
      assert_equal ['arithmetic'], r.stale.map(&:operator)
      partial = run_on(root, "! grep -q '1 - 2' lib/a.rb", shard: [1, 2])
      assert_equal [], partial.stale
      refute partial.complete
    end
  end

  def test_explicit_ignore_file_and_errors
    two = "- file: lib/a.rb\n  operator: arithmetic\n  line: nope\n  reason: r\n" \
          "- file: lib/a.rb\n  operator: arithmetic\n  line: gone\n  reason: r\n"
    with_project(LIB.merge('ign.yml' => two)) do |root|
      path = File.join(root, 'ign.yml')
      err = assert_raises(Mutaruby::Error) { run_on(root, 'true', ignore_file: path) }
      stale = 'STALE (the line is no longer in the file; re-review or remove the entry): #'
      assert_equal "ignore file #{path}:\n  #{stale}1 lib/a.rb arithmetic \"nope\"\n  #{stale}2 lib/a.rb arithmetic \"gone\"",
                   err.message
      missing = File.join(root, 'missing.yml')
      err = assert_raises(Mutaruby::Error) { run_on(root, 'true', ignore_file: missing) }
      assert_equal "ignore file not found: #{missing}", err.message
    end
  end

  def test_explicit_ignore_file_overrides_the_default
    ign = "- file: lib/a.rb\n  operator: arithmetic\n  line: X = 1 + 2\n  reason: r\n"
    with_project(LIB.merge('.mutaruby-ignore.yml' => "- nope\n", 'other.yml' => ign)) do |root|
      r = run_on(root, 'true', operators: ['arithmetic'], ignore_file: File.join(root, 'other.yml'))
      assert_equal [:equivalent], r.outcomes.map(&:status)
    end
  end

  def test_plan_applies_filters_and_reports_parse_errors
    with_project(LIB.merge('lib/bad.rb' => "def (\n", 'lib/z.rb' => "Z = 5\n")) do |root|
      runner = Mutaruby::Runner.new(options(root: root, command: 'true', operators: ['literal-int'], lines: [Mutaruby::Selection.parse_line_spec('lib/z.rb:1')]),
                                    out: StringIO.new)
      plan = runner.plan
      assert_equal ['lib/a.rb', 'lib/bad.rb', 'lib/z.rb'], plan[:files]
      assert_equal ['5 => 6', '5 => 4', '5 => 0', '5 => 1'], plan[:mutations].map(&:change)
      assert_equal [5, 6, 7, 8], plan[:mutations].map(&:id), 'ids are numbered across all files before filtering'
      assert_nil plan[:ignore]
      assert_equal 1, plan[:warnings].size
      refute plan[:complete]
      r = runner.run
      assert_equal 1, r.warnings.size
      assert_match(%r{\A#{Regexp.escape(root)}/lib/bad\.rb: cannot parse \(.+\); skipped\z}, r.warnings.first)
    end
  end

  def test_sources_are_read_as_utf8
    with_project(LIB) do |root|
      old = Encoding.default_external
      begin
        verbose = $VERBOSE
        $VERBOSE = nil
        Encoding.default_external = Encoding::ISO_8859_1
        plan = Mutaruby::Runner.new(options(root: root, command: 'true'), out: StringIO.new).plan
      ensure
        Encoding.default_external = old
        $VERBOSE = verbose
      end
      assert_equal Encoding::UTF_8, plan[:sources]['lib/a.rb'].encoding
      assert_equal LIB['lib/a.rb'], plan[:sources]['lib/a.rb']
    end
  end

  def test_progress_marks
    with_project(LIB) do |root|
      plan = Mutaruby::Runner.new(options(root: root, command: 'true'), out: StringIO.new).plan
      m3 = plan[:mutations][3]
      ign = [{ 'file' => 'lib/a.rb', 'operator' => m3.operator, 'line' => m3.line_text, 'mutation' => m3.change,
               'reason' => 'r' }].to_yaml
      File.write(File.join(root, '.mutaruby-ignore.yml'), ign)
      cmd = 'case "$MUTARUBY_MUTANT_ID" in 0) exit 1;; 1) sleep 30;; esac; exit 0'
      out = Recorder.new
      r = run_on(root, cmd, out: out, progress: true, jobs: 1, timeout: 0.3)
      marks = ".T#{'S' * (r.outcomes.size - 2)}"
      marks[3] = 'e'
      assert_equal "#{marks}\n", out.string
      assert_equal r.outcomes.size, out.flushes
      quiet = Recorder.new
      run_on(root, cmd, out: quiet, progress: false, jobs: 1, timeout: 0.3)
      assert_equal '', quiet.string
    end
  end

  def test_no_newline_without_mutants
    with_project(LIB) do |root|
      out = StringIO.new
      r = run_on(root, 'true', out: out, progress: true, patterns: ['nothing.rb'])
      assert_equal '', out.string
      assert_empty r.outcomes
      assert_nil r.score
    end
  end

  # One sandbox per worker, never more workers than mutants, at least one worker; all removed afterwards.
  def test_sandboxes_per_worker
    with_tmpdir do |tmp|
      with_project(LIB) do |root|
        cmd = "ls -d #{tmp}/mutaruby-* | wc -l | tr -d ' ' > #{tmp}/count-${MUTARUBY_MUTANT_ID:-base}"
        { 0 => 1, 1 => 1, 2 => 2, 5 => 5, 50 => 6 }.each do |jobs, want|
          r = run_on(root, cmd, jobs: jobs)
          assert_equal 6, r.outcomes.size
          assert_equal [jobs, 1].max, r.jobs
          assert_equal want.to_s, File.read(File.join(tmp, 'count-5')).strip, "jobs=#{jobs}"
          assert_equal '1', File.read(File.join(tmp, 'count-base')).strip
          assert_empty sandboxes_in(tmp)
        end
      end
    end
  end

  def test_copy_excludes_apply_to_every_sandbox
    with_project(LIB.merge('tmp/big' => 'x')) do |root|
      r = run_on(root, '[ ! -e tmp ]', jobs: 3, copy_excludes: ['tmp'])
      assert_equal [:survived], r.outcomes.map(&:status).uniq
      assert_raises(Mutaruby::BaselineFailed) { run_on(root, '[ ! -e tmp ]') }
    end
  end

  # Regression: an interrupted run kills the test commands in flight, starts no new ones and removes its sandboxes.
  def test_interrupt_stops_everything
    with_tmpdir do |tmp|
      with_project(LIB) do |root|
        cmd = "[ -z \"$MUTARUBY_MUTANT_ID\" ] || { echo $$ >> #{tmp}/pids; sleep 30; }"
        t = Thread.new { run_on(root, cmd, jobs: 2) }
        t.report_on_exception = false
        pids = File.join(tmp, 'pids')
        sleep 0.02 until File.exist?(pids) && File.readlines(pids).size == 2
        sleep 0.1
        t.raise(Interrupt)
        assert_raises(Interrupt) { t.join }
        started = File.readlines(pids).map(&:to_i)
        sleep 0.3
        assert_equal started, File.readlines(pids).map(&:to_i), 'no new mutant may start after an interrupt'
        started.each { |pid| assert_raises(Errno::ESRCH) { Process.kill(0, pid) } }
        assert_empty sandboxes_in(tmp)
      end
    end
  end

  # An IO that records flushes.
  class Recorder < StringIO
    attr_reader :flushes

    def flush
      @flushes = (@flushes || 0) + 1
      super
    end
  end
end
