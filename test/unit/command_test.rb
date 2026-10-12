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
      r = run_cmd('exit 0', d)
      assert_equal [:passed, 0, true, false, nil], [r.status, r.exitstatus, r.passed?, r.timeout?, r.output]
      r = run_cmd('exit 3', d)
      assert_equal [:failed, 3, false, false], [r.status, r.exitstatus, r.passed?, r.timeout?]
      assert_operator r.seconds, :>, 0
      assert_operator r.seconds, :<, 5
    end
  end

  def test_runs_in_the_given_directory_with_env_and_no_stdin
    Dir.mktmpdir do |d|
      with_env('MUTARUBY' => nil) do
        r = run_cmd('read x; echo "$(pwd -P) $MUTARUBY $X [$x]"; echo err >&2', d, env: { 'X' => 'y' }, capture: true)
        assert_equal "#{File.realpath(d)} 1 y []\nerr\n", r.output
      end
    end
  end

  # Regression: an outer run's mutant id must not leak into a nested run's baseline.
  def test_per_mutant_variables_are_not_inherited
    Dir.mktmpdir do |d|
      with_env('MUTARUBY_MUTANT_ID' => '17', 'MUTARUBY_FILE' => 'outer.rb') do
        r = run_cmd('echo "${MUTARUBY_MUTANT_ID:-none} ${MUTARUBY_FILE:-none}"', d, capture: true)
        assert_equal "none none\n", r.output
        r = run_cmd('echo "$MUTARUBY_MUTANT_ID"', d, env: { 'MUTARUBY_MUTANT_ID' => '3' }, capture: true)
        assert_equal "3\n", r.output
      end
    end
  end

  def test_captures_exactly_the_last_4000_bytes
    Dir.mktmpdir do |d|
      r = run_cmd("ruby -e 'print \"b\" + \"a\" * 9_996 + \"END\"'", d, capture: true)
      assert_equal "#{'a' * 3997}END", r.output
      assert_equal 'short', run_cmd('printf short', d, capture: true).output
      exact = "x#{'a' * 3998}y"
      assert_equal exact, run_cmd("printf #{exact}", d, capture: true).output
    end
  end

  def test_invalid_utf8_output_is_scrubbed
    Dir.mktmpdir do |d|
      r = run_cmd("printf 'a\\377b'", d, capture: true)
      assert_equal "a\uFFFDb", r.output
      assert_equal Encoding::UTF_8, r.output.encoding
      # the same when Ruby's default external encoding is not UTF-8
      verbose = $VERBOSE
      old = Encoding.default_external
      $VERBOSE = nil
      Encoding.default_external = Encoding::ISO_8859_1
      assert_equal "a\uFFFDb", run_cmd("printf 'a\\377b'", d, capture: true).output
    ensure
      Encoding.default_external = old if old
      $VERBOSE = verbose
    end
  end

  # Regression: a hanging mutant is killed (with everything it started) and reported as a timeout. A process that
  # handles SIGTERM gets to finish its handler: the group is signalled with TERM first and only killed once it exits
  # or the grace period ends.
  def test_timeout_sends_term_to_the_whole_group_and_waits_for_it
    Dir.mktmpdir do |d|
      script = File.join(d, 'child.sh')
      File.write(script, "trap 'sleep 0.3; echo graceful > term.txt; exit 0' TERM\necho $$ > child.pid\n" \
                         "while :; do sleep 0.05; done\n")
      t0 = now
      r = run_cmd("sh child.sh & wait", d, timeout: 0.5)
      took = now - t0
      assert r.timeout?
      assert_equal :timeout, r.status
      refute r.passed?
      assert_equal "graceful\n", File.read(File.join(d, 'term.txt'))
      assert_operator took, :>=, 0.8
      assert_operator took, :<, 1.4, "waited longer than the TERM handler needed"
      assert_operator r.seconds, :>=, 0.8
      assert dead?(File.read(File.join(d, 'child.pid')).to_i)
    end
  end

  def test_the_default_grace_period_is_used
    Dir.mktmpdir do |d|
      cmd = Mutaruby::Command.new('true', root: d)
      assert_equal 2, cmd.instance_variable_get(:@kill_grace)
    end
  end

  def test_a_group_that_ignores_term_is_killed_after_the_grace_period
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
    Dir.mktmpdir do |d|
      r = run_cmd('sleep 30 & echo $! > bg.pid; exit 0', d)
      assert r.passed?
      assert_operator r.seconds, :<, 1.5
      assert dead?(File.read(File.join(d, 'bg.pid')).to_i)
    end
  end

  # Regression: runs live in their own process groups, so an interrupted mutaruby must kill them itself.
  def test_kill_all_stops_runs_in_progress
    Dir.mktmpdir do |d|
      cmd = Mutaruby::Command.new('sleep 30', root: d)
      t = Thread.new { cmd.run(d) }
      sleep 0.02 until cmd.instance_variable_get(:@live).size == 1 && t.status == 'sleep'
      sleep 0.1
      cmd.kill_all
      r = t.value
      assert_equal :failed, r.status
      assert_operator r.seconds, :<, 1.5
      assert_empty cmd.instance_variable_get(:@live)
      cmd.kill_all
    end
  end

  def test_fast_command_is_not_a_timeout
    Dir.mktmpdir { |d| assert run_cmd('true', d, timeout: 5).passed? }
  end

  # Regression: Bundler's BUNDLE_GEMFILE must point into the sandbox, or `bundle exec` loads the user's checkout.
  def test_bundle_gemfile_is_redirected_into_the_sandbox
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |box|
        echo = 'echo "$BUNDLE_GEMFILE|$BUNDLE_APP_CONFIG"'
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
