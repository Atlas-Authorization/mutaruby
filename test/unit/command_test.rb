# frozen_string_literal: true

require_relative '../test_helper'

class CommandTest < Minitest::Test
  include TestHelpers

  def run_cmd(cmd, dir, **kw)
    Mutaruby::Command.new(cmd, root: dir).run(dir, **kw)
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # True once pid is gone (within 2 seconds). An orphan killed with its group can stay a zombie until its new parent
  # reaps it (for good, in a container whose init does not reap); a zombie counts as gone.
  def dead?(pid)
    deadline = now + 2
    until gone?(pid)
      return false if now > deadline

      sleep 0.02
    end
    true
  end

  def gone?(pid)
    return process_gone?(pid) if windows?

    Process.kill(0, pid)
    stat = "/proc/#{pid}/stat"
    File.exist?(stat) && File.read(stat).split[2] == 'Z'
  rescue Errno::ESRCH, Errno::ENOENT
    true
  end

  def test_constants
    assert_equal 4000, Mutaruby::Command::OUTPUT_TAIL
    assert_equal 2, Mutaruby::Command::KILL_GRACE
  end

  def test_exit_status_decides
    Dir.mktmpdir do |d|
      r = run_cmd(rb('exit 0'), d)
      assert_equal [:passed, 0, true, false, nil], [r.status, r.exitstatus, r.passed?, r.timeout?, r.output]
      r = run_cmd(rb('exit 3'), d)
      assert_equal [:failed, 3, false, false], [r.status, r.exitstatus, r.passed?, r.timeout?]
      assert_operator r.seconds, :>, 0
      assert_operator r.seconds, :<, 5
    end
  end

  def test_runs_in_the_given_directory_with_env_and_no_stdin
    Dir.mktmpdir do |d|
      with_env('MUTARUBY' => nil) do
        code = '$stdout.sync = true; x = $stdin.read; puts "#{File.realpath(Dir.pwd)} #{ENV["MUTARUBY"]} ' \
               '#{ENV["X"]} [#{x}]"; $stderr.puts "err"'
        r = run_cmd(rb(code), d, env: { 'X' => 'y' }, capture: true)
        assert_equal "#{File.realpath(d)} 1 y []\nerr\n", r.output
      end
    end
  end

  # Regression: an outer run's mutant id must not leak into a nested run's baseline.
  def test_per_mutant_variables_are_not_inherited
    Dir.mktmpdir do |d|
      with_env('MUTARUBY_MUTANT_ID' => '17', 'MUTARUBY_FILE' => 'outer.rb') do
        show = rb('puts "#{ENV.fetch("MUTARUBY_MUTANT_ID", "none")} #{ENV.fetch("MUTARUBY_FILE", "none")}"')
        assert_equal "none none\n", run_cmd(show, d, capture: true).output
        r = run_cmd(rb('puts ENV["MUTARUBY_MUTANT_ID"]'), d, env: { 'MUTARUBY_MUTANT_ID' => '3' }, capture: true)
        assert_equal "3\n", r.output
      end
    end
  end

  def test_captures_exactly_the_last_4000_bytes
    Dir.mktmpdir do |d|
      r = run_cmd(rb('print "b" + "a" * 9_996 + "END"'), d, capture: true)
      assert_equal "#{'a' * 3997}END", r.output
      assert_equal 'short', run_cmd(rb('print "short"'), d, capture: true).output
      exact = "x#{'a' * 3998}y"
      assert_equal exact, run_cmd(rb("print #{exact.inspect}"), d, capture: true).output
    end
  end

  def test_invalid_utf8_output_is_scrubbed
    Dir.mktmpdir do |d|
      bad = rb('$stdout.binmode; print "a\\xFFb".b')
      r = run_cmd(bad, d, capture: true)
      assert_equal "a�b", r.output
      assert_equal Encoding::UTF_8, r.output.encoding
      # the same when Ruby's default external encoding is not UTF-8
      verbose = $VERBOSE
      old = Encoding.default_external
      $VERBOSE = nil
      Encoding.default_external = Encoding::ISO_8859_1
      assert_equal "a�b", run_cmd(bad, d, capture: true).output
    ensure
      Encoding.default_external = old if old
      $VERBOSE = verbose
    end
  end

  # Regression: a hanging mutant is killed together with everything it started (here: a grandchild process).
  def test_timeout_kills_the_whole_process_tree
    Dir.mktmpdir do |d|
      tree = rb('require "rbconfig"; pid = spawn(RbConfig.ruby, "-e", "sleep 30"); File.write("child.pid", pid.to_s); sleep 30')
      t0 = now
      r = Mutaruby::Command.new(tree, root: d, kill_grace: 0.5).run(d, timeout: hang_timeout + 0.5)
      assert r.timeout?
      assert_equal :timeout, r.status
      refute r.passed?
      assert_operator now - t0, :<, 10
      assert dead?(File.read(File.join(d, 'child.pid')).to_i)
    end
  end

  # A process that handles SIGTERM gets to finish its handler: the group gets TERM first and is only killed once it
  # exits or the grace period ends.
  def test_timeout_sends_term_to_the_whole_group_and_waits_for_it
    posix_only!
    Dir.mktmpdir do |d|
      script = File.join(d, 'child.sh')
      File.write(script, "trap 'sleep 0.3; echo graceful > term.txt; exit 0' TERM\necho $$ > child.pid\n" \
                         "while :; do sleep 0.05; done\n")
      t0 = now
      r = run_cmd("sh child.sh & wait", d, timeout: 0.5)
      took = now - t0
      assert r.timeout?
      assert_equal "graceful\n", File.read(File.join(d, 'term.txt'))
      assert_operator took, :>=, 0.8
      assert_operator took, :<, 1.4, "waited longer than the TERM handler needed"
      assert_operator r.seconds, :>=, 0.8
      assert dead?(File.read(File.join(d, 'child.pid')).to_i)
    end
  end

  def test_the_default_grace_period_and_platform
    Dir.mktmpdir do |d|
      cmd = Mutaruby::Command.new('x', root: d)
      assert_equal 2, cmd.instance_variable_get(:@kill_grace)
      assert_same Mutaruby::Platform.current, cmd.instance_variable_get(:@platform)
    end
  end

  def test_a_group_that_ignores_term_is_killed_after_the_grace_period
    posix_only!
    Dir.mktmpdir do |d|
      cmd = "trap '' TERM; sh -c 'echo $$ > child.pid; trap \"\" TERM; while :; do sleep 0.05; done' & wait"
      t0 = now
      r = Mutaruby::Command.new(cmd, root: d, kill_grace: 0.6).run(d, timeout: 0.2)
      took = now - t0
      assert r.timeout?
      assert_operator took, :>=, 0.8
      assert_operator took, :<, 1.6
      assert dead?(File.read(File.join(d, 'child.pid')).to_i)
    end
  end

  # Regression: processes a passing run leaves behind (a server, a forked worker) are killed with it, so they cannot
  # interfere with the next mutant.
  def test_leftover_background_processes_are_killed
    posix_only!
    Dir.mktmpdir do |d|
      r = run_cmd('sleep 30 & echo $! > bg.pid; exit 0', d)
      assert r.passed?
      assert_operator r.seconds, :<, 1.5
      assert dead?(File.read(File.join(d, 'bg.pid')).to_i)
    end
  end

  # Records the platform calls Command makes; spawning is delegated to the real platform.
  class FakePlatform
    attr_reader :calls

    def initialize(leftovers:, alive: [])
      @real = Mutaruby::Platform.current
      @leftovers = leftovers
      @alive = alive
      @calls = []
    end

    def spawn_args(command)
      @calls << [:spawn_args, command]
      @real.spawn_args(command)
    end

    def spawn_options = @real.spawn_options
    def stop_leftovers? = @leftovers

    def stop_tree(pid, graceful:)
      @calls << [:stop_tree, graceful]
      @real.stop_tree(pid, graceful: graceful)
    end

    def alive?(_pid, waiter)
      @calls << [:alive?, waiter.class]
      @alive.shift || false
    end
  end

  def test_the_platform_starts_and_stops_runs
    Dir.mktmpdir do |d|
      quick = rb('exit 0')
      keep = FakePlatform.new(leftovers: false)
      assert Mutaruby::Command.new(quick, root: d, platform: keep).run(d).passed?
      assert_equal [[:spawn_args, quick]], keep.calls, 'no tree stop after a normal exit when the platform says so'
      stop = FakePlatform.new(leftovers: true)
      Mutaruby::Command.new(quick, root: d, platform: stop).run(d)
      assert_equal [[:spawn_args, quick], [:stop_tree, true], [:alive?, Process::Waiter], [:stop_tree, false]], stop.calls
      slow = FakePlatform.new(leftovers: false, alive: [true, true])
      r = Mutaruby::Command.new(rb('sleep 30'), root: d, platform: slow, kill_grace: 5).run(d, timeout: 0.2)
      assert r.timeout?
      assert_equal [[:stop_tree, true], [:alive?, Process::Waiter], [:alive?, Process::Waiter], [:alive?, Process::Waiter], [:stop_tree, false]], slow.calls.drop(1)
    end
  end

  # Regression: runs live in their own process groups, so an interrupted mutaruby must kill them itself.
  def test_kill_all_stops_runs_in_progress
    Dir.mktmpdir do |d|
      cmd = Mutaruby::Command.new(rb('sleep 30'), root: d, kill_grace: 0.3)
      t = Thread.new { cmd.run(d) }
      sleep 0.02 until cmd.instance_variable_get(:@live).size == 1 && t.status == 'sleep'
      sleep 0.3
      cmd.kill_all
      r = t.value
      assert_equal :failed, r.status
      assert_operator r.seconds, :<, 3
      assert_empty cmd.instance_variable_get(:@live)
      cmd.kill_all
    end
  end

  def test_fast_command_is_not_a_timeout
    Dir.mktmpdir { |d| assert run_cmd(rb('exit 0'), d, timeout: 5).passed? }
  end

  # Regression: Bundler's BUNDLE_GEMFILE must point into the sandbox, or `bundle exec` loads the user's checkout.
  # (RUBYOPT is cleared so that, under `bundle exec`, the probe does not try to load these made-up Gemfiles.)
  def test_bundle_gemfile_is_redirected_into_the_sandbox
    with_env('RUBYOPT' => nil) { bundle_gemfile_cases }
  end

  def bundle_gemfile_cases
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |box|
        echo = rb('puts "#{ENV["BUNDLE_GEMFILE"]}|#{ENV["BUNDLE_APP_CONFIG"]}"')
        with_env('BUNDLE_GEMFILE' => File.join(root, 'Gemfile'), 'BUNDLE_APP_CONFIG' => '/elsewhere/.bundle') do
          r = Mutaruby::Command.new(echo, root: root).run(box, capture: true)
          assert_equal "#{File.join(box, 'Gemfile')}|/elsewhere/.bundle\n", r.output
        end
        with_env('BUNDLE_GEMFILE' => nil, 'BUNDLE_APP_CONFIG' => File.join(root, '.bundle')) do
          r = Mutaruby::Command.new(echo, root: root).run(box, capture: true)
          assert_equal "|#{File.join(box, '.bundle')}\n", r.output
        end
        Dir.chdir(root) do
          with_env('BUNDLE_GEMFILE' => 'sub/Gemfile', 'BUNDLE_APP_CONFIG' => nil) do
            r = Mutaruby::Command.new(echo, root: '.').run(box, capture: true)
            assert_equal "#{File.join(box, 'sub/Gemfile')}|\n", r.output
          end
        end
      end
    end
  end
end
