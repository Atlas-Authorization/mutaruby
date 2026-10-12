# frozen_string_literal: true

require_relative '../test_helper'

class CommandTest < Minitest::Test
  include TestHelpers

  def run_cmd(cmd, dir, **kw)
    Mutaruby::Command.new(cmd, root: dir).run(dir, **kw)
  end

  def test_exit_status_decides
    Dir.mktmpdir do |d|
      r = run_cmd('exit 0', d)
      assert r.passed?
      refute r.timeout?
      assert_equal :passed, r.status
      r = run_cmd('exit 3', d)
      refute r.passed?
      assert_equal [:failed, 3], [r.status, r.exitstatus]
    end
  end

  def test_runs_in_the_given_directory_with_env
    Dir.mktmpdir do |d|
      r = run_cmd('echo "$(pwd -P) $MUTARUBY $X"', d, env: { 'X' => 'y' }, capture: true)
      assert_equal "#{File.realpath(d)} 1 y", r.output.strip
      assert_nil run_cmd('echo hi', d).output
    end
  end

  # Regression: an outer run's mutant id must not leak into a nested run's baseline.
  def test_per_mutant_variables_are_not_inherited
    Dir.mktmpdir do |d|
      old = ENV.to_h.slice('MUTARUBY_MUTANT_ID', 'MUTARUBY_FILE')
      ENV['MUTARUBY_MUTANT_ID'] = '17'
      ENV['MUTARUBY_FILE'] = 'outer.rb'
      r = run_cmd('echo "${MUTARUBY_MUTANT_ID:-none} ${MUTARUBY_FILE:-none}"', d, capture: true)
      assert_equal 'none none', r.output.strip
      r = run_cmd('echo "$MUTARUBY_MUTANT_ID"', d, env: { 'MUTARUBY_MUTANT_ID' => '3' }, capture: true)
      assert_equal '3', r.output.strip
    ensure
      ENV.delete('MUTARUBY_MUTANT_ID')
      ENV.delete('MUTARUBY_FILE')
      ENV.update(old)
    end
  end

  def test_captures_only_the_tail
    Dir.mktmpdir do |d|
      r = run_cmd("ruby -e 'print \"a\" * 10_000 + \"END\"'", d, capture: true)
      assert_equal Mutaruby::Command::OUTPUT_TAIL, r.output.bytesize
      assert r.output.end_with?('END')
    end
  end

  # Regression: a hanging mutant is killed (with everything it started) and reported as a timeout.
  def test_timeout_kills_the_process_group
    Dir.mktmpdir do |d|
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      r = run_cmd("sleep 30 & echo $! > child.pid; sleep 30", d, timeout: 0.3)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      assert r.timeout?
      refute r.passed?
      assert_operator took, :<, 10
      assert_operator r.seconds, :>=, 0.3
      child = File.read(File.join(d, 'child.pid')).to_i
      sleep 0.2
      assert_raises(Errno::ESRCH) { Process.kill(0, child) }
    end
  end

  # Regression: runs live in their own process groups, so an interrupted mutaruby must kill them itself.
  def test_kill_all_stops_runs_in_progress
    Dir.mktmpdir do |d|
      cmd = Mutaruby::Command.new('sleep 30', root: d)
      t = Thread.new { cmd.run(d) }
      sleep 0.05 until t.status == 'sleep' && cmd.instance_variable_get(:@live).any?
      cmd.kill_all
      r = t.value
      assert_equal :failed, r.status
      assert_operator r.seconds, :<, 10
      assert_empty cmd.instance_variable_get(:@live)
    end
  end

  def test_fast_command_is_not_a_timeout
    Dir.mktmpdir { |d| assert run_cmd('true', d, timeout: 5).passed? }
  end

  # Regression: Bundler's BUNDLE_GEMFILE must point into the sandbox, or `bundle exec` loads the user's checkout.
  def test_bundle_gemfile_is_redirected_into_the_sandbox
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |box|
        old = ENV.to_h.slice('BUNDLE_GEMFILE', 'BUNDLE_APP_CONFIG')
        begin
          ENV['BUNDLE_GEMFILE'] = File.join(root, 'Gemfile')
          ENV['BUNDLE_APP_CONFIG'] = '/elsewhere/.bundle'
          r = Mutaruby::Command.new('echo "$BUNDLE_GEMFILE|$BUNDLE_APP_CONFIG"', root: root).run(box, capture: true)
          assert_equal "#{File.join(box, 'Gemfile')}|/elsewhere/.bundle", r.output.strip
        ensure
          ENV.delete('BUNDLE_GEMFILE')
          ENV.delete('BUNDLE_APP_CONFIG')
          ENV.update(old)
        end
      end
    end
  end
end
