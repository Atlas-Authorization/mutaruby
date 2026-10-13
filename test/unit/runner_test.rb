# frozen_string_literal: true

require_relative '../test_helper'

class RunnerTest < Minitest::Test
  include TestHelpers

  LIB = { 'lib/a.rb' => "# é\r\nX = 1 + 2\n" }.freeze
  TWO = { 'lib/a.rb' => "A = 1\n", 'lib/b.rb' => "B = 7\n" }.freeze

  def run_on(root, command, out: StringIO.new, **kw)
    Mutaruby::Runner.new(options(root: root, command: command, **kw), out: out).run
  end

  def statuses(report)
    report.outcomes.to_h { |o| [o.mutation.change, o.status] }
  end

  # Records, per run, what the test command saw: every file of the project and the per-mutant variables.
  def recorder(log)
    rb(%(id = ENV.fetch("MUTARUBY_MUTANT_ID", "base")
         File.binwrite("#{log}/\#{id}.src", Dir["lib/*.rb"].sort.map { |f| File.binread(f) }.join)
         File.write("#{log}/\#{id}.env", "\#{ENV["MUTARUBY_FILE"]}|\#{ENV["MUTARUBY"]}\\n")))
  end

  def killer = kill_if('1 - 2')
  def ok = rb('exit 0')

  # A private TMPDIR, so the sandboxes a run creates can be counted.
  # (Removed with rm_rf: on Windows a file an interrupted run's output went to can stay locked for a moment.)
  def with_tmpdir
    t = Dir.mktmpdir
    with_env('TMPDIR' => t) { yield t }
  ensure
    FileUtils.rm_rf(t) if t
  end

  def sandboxes_in(tmp) = Dir.glob(File.join(tmp, "#{sandbox_prefix}*"))

  def test_options_defaults
    o = Mutaruby::Runner::Options.build
    assert_equal ['.', [], 1, 3.0, [], [], [], [], [], false],
                 [o.root, o.patterns, o.jobs, o.timeout_factor, o.methods, o.exclude_methods, o.lines, o.exclude_lines,
                  o.copy_excludes, o.progress]
    assert_nil o.timeout
    assert_equal [[], false, :text], [o.subjects, o.coverage, o.renderer]
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
        cmd = rb('puts "suite-output"; exit 3')
        err = assert_raises(Mutaruby::BaselineFailed) { run_on(root, cmd) }
        assert_equal "the test command fails on the UNMUTATED code (exit 3); every mutant would count as killed, so " \
                     "nothing would be measured.\ncommand: #{cmd}\n--- output (tail) ---\nsuite-output\n", err.message
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
      r = run_on(root, killer)
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
      assert_equal killer, r.command
      assert_operator r.seconds, :>, 0
      assert_operator r.seconds, :<, 60
      assert_operator r.baseline_seconds, :>, 0
      assert_operator r.seconds, :>, r.baseline_seconds
    end
  end

  def test_relative_root
    with_project(LIB) do |root|
      Dir.chdir(root) do
        r = run_on('.', ok, operators: ['arithmetic'])
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
        # one file per run: concurrent appends to one file can lose lines on Windows
        cmd = rb(%(id = ENV.fetch("MUTARUBY_MUTANT_ID", "base"); File.write("#{log}/pid-\#{id}", "\#{Process.pid} \#{id}")))
        r = run_on(root, cmd, jobs: 3)
        lines = Dir[File.join(log, 'pid-*')].map { |f| File.read(f).split }
        assert_equal r.outcomes.size + 1, lines.size
        # distinct process ids (only meaningful where ids are not reused at once: Windows reuses them quickly)
        assert_equal lines.size, lines.map(&:first).uniq.size unless windows?
        assert_equal ['base'] + r.outcomes.map { |o| o.mutation.id.to_s }, lines.map(&:last).sort_by { |x| x == 'base' ? -1 : x.to_i }
      end
    end
  end

  # Regression: the user's files are never written, whatever the test command does.
  def test_original_files_are_never_touched
    with_project(LIB) do |root|
      before = snapshot(root)
      assert_raises(Mutaruby::BaselineFailed) { run_on(root, rb('File.open("lib/a.rb", "a") { |f| f.puts "junk" }; exit 1')) }
      run_on(root, rb('File.open("lib/a.rb", "a") { |f| f.puts "x" } if File.read("lib/a.rb").include?("1 + 2")'))
      assert_equal before, snapshot(root)
    end
  end

  def test_timeouts_are_kills_reported_separately
    with_project(LIB) do |root|
      r = run_on(root, rb('sleep 30 if File.read("lib/a.rb").include?("1 - 2")'), timeout: hang_timeout)
      assert_equal :timeout, statuses(r)['+ => -']
      assert_equal 1, r.count(:timeout)
      assert_equal 1, r.killed
      assert_in_delta hang_timeout, r.timeout
    end
  end

  # The default timeout is the baseline time x factor + 5 seconds, rounded up.
  def test_default_timeout_comes_from_the_baseline
    with_project(LIB) do |root|
      r = run_on(root, rb('sleep 0.4 unless ENV["MUTARUBY_MUTANT_ID"]'), operators: ['arithmetic'], timeout_factor: 2.5)
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
      r = run_on(root, killer)
      assert_equal :equivalent, statuses(r)['1 => 0']
      assert_equal 'pretend this is equivalent', r.outcomes.find { |o| o.status == :equivalent }.ignore.reason
      assert_equal :killed, statuses(r)['+ => -']
      assert_equal 1, r.count(:equivalent)
      assert_equal ['arithmetic'], r.stale.map(&:operator)
      partial = run_on(root, killer, shard: [1, 2])
      assert_equal [], partial.stale
      refute partial.complete
    end
  end

  def test_explicit_ignore_file_and_errors
    two = "- file: lib/a.rb\n  operator: arithmetic\n  line: nope\n  reason: r\n" \
          "- file: lib/a.rb\n  operator: arithmetic\n  line: gone\n  reason: r\n"
    with_project(LIB.merge('ign.yml' => two)) do |root|
      path = File.join(root, 'ign.yml')
      err = assert_raises(Mutaruby::Error) { run_on(root, ok, ignore_file: path) }
      stale = 'STALE (the line is no longer in the file; re-review or remove the entry): #'
      assert_equal "ignore file #{path}:\n  #{stale}1 lib/a.rb arithmetic \"nope\"\n  #{stale}2 lib/a.rb arithmetic \"gone\"",
                   err.message
      missing = File.join(root, 'missing.yml')
      err = assert_raises(Mutaruby::Error) { run_on(root, ok, ignore_file: missing) }
      assert_equal "ignore file not found: #{missing}", err.message
    end
  end

  def test_explicit_ignore_file_overrides_the_default
    ign = "- file: lib/a.rb\n  operator: arithmetic\n  line: X = 1 + 2\n  reason: r\n"
    with_project(LIB.merge('.mutaruby-ignore.yml' => "- nope\n", 'other.yml' => ign)) do |root|
      r = run_on(root, ok, operators: ['arithmetic'], ignore_file: File.join(root, 'other.yml'))
      assert_equal [:equivalent], r.outcomes.map(&:status)
    end
  end

  def test_plan_applies_filters_and_reports_parse_errors
    with_project(LIB.merge('lib/bad.rb' => "def (\n", 'lib/z.rb' => "Z = 5\n")) do |root|
      runner = Mutaruby::Runner.new(options(root: root, command: ok, operators: ['literal-int'], lines: [Mutaruby::Selection.parse_line_spec('lib/z.rb:1')]),
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
        plan = Mutaruby::Runner.new(options(root: root, command: ok), out: StringIO.new).plan
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
      plan = Mutaruby::Runner.new(options(root: root, command: ok), out: StringIO.new).plan
      m3 = plan[:mutations][3]
      ign = [{ 'file' => 'lib/a.rb', 'operator' => m3.operator, 'line' => m3.line_text, 'mutation' => m3.change,
               'reason' => 'r' }].to_yaml
      File.write(File.join(root, '.mutaruby-ignore.yml'), ign)
      cmd = rb('case ENV["MUTARUBY_MUTANT_ID"] when "0" then exit 1 when "1" then sleep 30 end')
      out = Recorder.new
      r = run_on(root, cmd, out: out, progress: true, jobs: 1, timeout: hang_timeout)
      marks = ".T#{'S' * (r.outcomes.size - 2)}"
      marks[3] = 'e'
      assert_equal "#{marks}\n", out.string
      assert_equal r.outcomes.size, out.flushes
      quiet = Recorder.new
      run_on(root, cmd, out: quiet, progress: false, jobs: 1, timeout: hang_timeout)
      assert_equal '', quiet.string
    end
  end

  def test_no_newline_without_mutants
    with_project(LIB) do |root|
      out = StringIO.new
      r = run_on(root, ok, out: out, progress: true, patterns: ['nothing.rb'])
      assert_equal '', out.string
      assert_empty r.outcomes
      assert_nil r.score
    end
  end

  # One sandbox per worker, never more workers than mutants, at least one worker; all removed afterwards.
  def test_sandboxes_per_worker
    with_tmpdir do |tmp|
      with_project(LIB) do |root|
        { 0 => 1, 1 => 1, 2 => 2, 5 => 5, 50 => 6 }.each do |jobs, want|
          count = %(Dir.glob("#{tmp}/#{sandbox_prefix}*").size.to_s)
          # retried: on Windows a virus scanner can hold a just-created file for a moment
          cmd = rb(%(path = "#{tmp}/count-#{jobs}-\#{ENV.fetch("MUTARUBY_MUTANT_ID", "base")}"
                     10.times { begin; File.write(path, #{count}); break; rescue SystemCallError; sleep 0.2; end }))
          # many Rubies starting at once are slow on a Windows runner; the default timeout is tuned for one
          r = run_on(root, cmd, jobs: jobs, timeout: windows? ? 60 : nil)
          assert_equal [:survived], r.outcomes.map(&:status).uniq, "jobs=#{jobs}"
          assert_equal 6, r.outcomes.size
          assert_equal [jobs, 1].max, r.jobs
          assert_equal want.to_s, File.read(File.join(tmp, "count-#{jobs}-5")).strip, "jobs=#{jobs}"
          assert_equal '1', File.read(File.join(tmp, "count-#{jobs}-base")).strip
          assert_empty sandboxes_in(tmp)
        end
      end
    end
  end

  def test_copy_excludes_apply_to_every_sandbox
    with_project(LIB.merge('tmp/big' => 'x')) do |root|
      absent = rb('exit(File.exist?("tmp") ? 1 : 0)')
      r = run_on(root, absent, jobs: 3, copy_excludes: ['tmp'])
      assert_equal [:survived], r.outcomes.map(&:status).uniq
      assert_raises(Mutaruby::BaselineFailed) { run_on(root, absent) }
    end
  end

  # Regression: an interrupted run kills the test commands in flight, starts no new ones and removes its sandboxes.
  def test_interrupt_stops_everything
    with_tmpdir do |tmp|
      with_project(LIB) do |root|
        cmd = rb(%(exit 0 unless ENV["MUTARUBY_MUTANT_ID"]; File.write("#{tmp}/pid-\#{Process.pid}", ""); sleep 30))
        runner = Mutaruby::Runner.new(options(root: root, command: cmd, jobs: 2, timeout: 120), out: StringIO.new)
        t = Thread.new { runner.run }
        t.report_on_exception = false
        pids = -> { Dir[File.join(tmp, 'pid-*')].map { |f| f[/\d+\z/].to_i }.sort }
        sleep 0.02 until pids.call.size == 2
        sleep 0.1
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        SlowRestore.delay = 0.5 # a worker still busy after its run is killed: the runner must wait for it
        t.raise(Interrupt)
        assert_raises(Interrupt) { t.join }
        SlowRestore.delay = nil
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 8, 'the run stops without finishing the queue'
        assert_equal [false, false], runner.instance_variable_get(:@threads).map(&:alive?), 'workers are stopped'
        started = pids.call
        sleep 0.3
        assert_equal started, pids.call, 'no new mutant may start after an interrupt'
        started.each { |pid| assert process_gone?(pid), "process #{pid} still running" }
        assert_empty sandboxes_in(tmp)
      end
    end
  end

  # Makes a worker take a while to restore its sandbox after a run (only while `delay` is set).
  module SlowRestore
    class << self
      attr_accessor :delay
    end

    def with_file(*args)
      super(*args) do
        result = yield
        sleep SlowRestore.delay if SlowRestore.delay
        result
      end
    end
  end
  Mutaruby::Sandbox.prepend(SlowRestore)

  # An IO that records flushes.
  class Recorder < StringIO
    attr_reader :flushes

    def flush
      @flushes = (@flushes || 0) + 1
      super
    end
  end

  COVERED = {
    'lib/a.rb' => "module A\n  def self.one\n    1\n  end\n\n  def self.two\n    2\n  end\nend\n",
    'test/a_test.rb' => <<~RUBY
      require 'minitest/autorun'
      require_relative '../lib/a'

      class ATest < Minitest::Test
        def setup
          File.write(File.join(ENV['LOG'], "\#{ENV.fetch('MUTARUBY_MUTANT_ID', 'base')}-\#{name}"), '') if ENV['LOG']
        end

        def test_one
          assert_equal 1, A.one
        end

        def test_two
          assert_equal 2, A.two
        end
      end
    RUBY
  }.freeze

  # With coverage, the baseline maps tests to lines and each mutant runs only the tests that reach it.
  def test_coverage_based_selection
    with_project(COVERED) do |root|
      Dir.mktmpdir do |log|
        with_env('LOG' => log) do
          cmd = %("#{RbConfig.ruby}" test/a_test.rb)
          r = run_on(root, cmd, coverage: true, operators: ['literal-int'], jobs: 1)
          assert_equal 'minitest', r.coverage
          assert_equal [], r.warnings
          ran = Dir.children(log).sort
          r.outcomes.each do |o|
            m = o.mutation
            want = m.lineno == 3 ? 'test_one' : 'test_two'
            assert_equal 1, o.tests, m.label
            assert_equal ["#{m.id}-#{want}"], ran.select { |f| f.start_with?("#{m.id}-") }, m.label
            assert_equal :killed, o.status
          end
          assert_equal %w[base-test_one base-test_two], ran.select { |f| f.start_with?('base-') }
          plain = run_on(root, cmd, operators: ['literal-int'], jobs: 1)
          assert_nil plain.coverage
          assert_equal [nil], plain.outcomes.map(&:tests).uniq
        end
      end
    end
  end

  # A test command that is not Minitest or RSpec cannot be mapped: everything runs the whole command.
  def test_coverage_without_a_supported_framework
    with_project(LIB) do |root|
      r = run_on(root, killer, coverage: true, operators: ['arithmetic'])
      assert_nil r.coverage
      assert_equal ['coverage: no Minitest or RSpec tests were recorded in the baseline run; every mutant runs the ' \
                    'whole test command'], r.warnings
      assert_equal [nil], r.outcomes.map(&:tests)
      assert_equal [:killed], r.outcomes.map(&:status)
    end
  end

  def test_subjects_and_renderer_reach_the_plan
    src = "class K\n  def a = [1, 2]\nend\nclass L\n  def b = 3\nend\n"
    with_project('lib/k.rb' => src) do |root|
      plan = Mutaruby::Runner.new(options(root: root, command: ok, subjects: ['K'], operators: ['element-removal'],
                                          renderer: :unparser), out: StringIO.new).plan
      assert_equal ['[1, 2] => [2]', '[1, 2] => [1]'], plan[:mutations].map(&:change)
      refute plan[:complete]
    end
  end

  SAFE = {
    'lib/s.rb' => "module S\n  def self.safe(x)\n    Integer(x)\n  rescue ArgumentError\n    0\n  end\nend\n",
    'test/s_test.rb' => <<~RUBY
      require 'minitest/autorun'
      require_relative '../lib/s'

      class STest < Minitest::Test
        def test_ok
          assert_equal 3, S.safe('3')
        end

        def test_bad
          assert_equal 0, S.safe('x')
        end
      end
    RUBY
  }.freeze

  # A mutant spanning several lines selects the tests of all of them: removing the rescue clause (its first line has
  # no coverage of its own) runs the test that reaches the clause's body.
  def test_coverage_of_multi_line_mutants
    with_project(SAFE) do |root|
      r = run_on(root, %("#{RbConfig.ruby}" test/s_test.rb), coverage: true, operators: ['rescue-removal'])
      assert_equal [[1, :killed]], r.outcomes.map { |o| [o.tests, o.status] }
    end
  end

  # The probe is loaded only with --coverage.
  def test_baseline_loads_the_probe_only_with_coverage
    with_project(LIB) do |root|
      Dir.mktmpdir do |log|
        show = rb(%(File.write("#{log}/\#{ENV.fetch('MUTARUBY_MUTANT_ID', 'base')}", ENV.fetch('MUTARUBY_COVERAGE_OUT', '-'))))
        run_on(root, show, operators: ['arithmetic'])
        assert_equal '-', File.read(File.join(log, 'base'))
        run_on(root, show, operators: ['arithmetic'], coverage: true)
        assert File.read(File.join(log, 'base')).end_with?('coverage.json')
      end
    end
  end

  # A Minitest suite without tests records nothing usable: same fallback and warning.
  def test_coverage_with_an_empty_suite
    empty = "require 'minitest/autorun'\nrequire_relative '../lib/a'\nclass EmptyTest < Minitest::Test\nend\n"
    with_project(COVERED.merge('test/a_test.rb' => empty)) do |root|
      r = run_on(root, %("#{RbConfig.ruby}" test/a_test.rb), coverage: true, operators: ['literal-int'])
      assert_nil r.coverage
      assert_equal 1, r.warnings.size
      assert_equal [nil], r.outcomes.map(&:tests).uniq
    end
  end

  def test_default_renderer_is_text
    with_project('lib/k.rb' => "X = [1,  2]\n") do |root|
      plan = Mutaruby::Runner.new(options(root: root, command: ok, operators: ['element-removal']), out: StringIO.new).plan
      assert_equal ['1, 2 => 2', '1, 2 => 1'], plan[:mutations].map(&:change)
    end
  end

  # Interrupted during the baseline (before any worker exists): the interrupt propagates and nothing is left behind.
  def test_interrupt_during_the_baseline
    with_tmpdir do |tmp|
      with_project(LIB) do |root|
        cmd = rb(%(File.write("#{tmp}/base-\#{Process.pid}", ""); sleep 30))
        runner = Mutaruby::Runner.new(options(root: root, command: cmd), out: StringIO.new)
        t = Thread.new { runner.run }
        t.report_on_exception = false
        sleep 0.02 until Dir[File.join(tmp, 'base-*')].any?
        t.raise(Interrupt)
        assert_raises(Interrupt) { t.join }
        assert process_gone?(Dir[File.join(tmp, 'base-*')].first[/\d+\z/].to_i)
        assert_empty sandboxes_in(tmp) unless windows? # (Windows may still hold the directory of a process just stopped)
      end
    end
  end

  # Makes Sandbox#cleanup fail (only while `error` is set), like a directory Windows keeps locked.
  module LockedCleanup
    class << self
      attr_accessor :error
    end

    def cleanup
      raise LockedCleanup.error if LockedCleanup.error

      super
    end
  end
  Mutaruby::Sandbox.prepend(LockedCleanup)

  # A sandbox that cannot be removed is an error of its own, unless the run is already failing: then the original
  # error (here a failing baseline) is what the user sees.
  def test_cleanup_errors_do_not_hide_the_real_error
    with_project(LIB) do |root|
      LockedCleanup.error = Errno::EACCES
      assert_raises(Errno::EACCES) { run_on(root, ok, operators: ['arithmetic']) }
      assert_raises(Mutaruby::BaselineFailed) { run_on(root, rb('exit 1')) }
    ensure
      LockedCleanup.error = nil
    end
  end
end
