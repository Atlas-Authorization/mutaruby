# frozen_string_literal: true

require_relative '../test_helper'

class PlatformTest < Minitest::Test
  include TestHelpers

  P = Mutaruby::Platform

  # A pid that no longer exists: a process that has exited and been reaped.
  def dead_pid
    pid = Process.spawn(RbConfig.ruby, '--disable-gems', '-e', 'exit 0')
    Process.wait(pid)
    pid
  end

  def test_detection
    assert P.windows?('mingw32')
    assert P.windows?('mswin64')
    assert P.windows?('cygwin')
    refute P.windows?('linux-gnu')
    refute P.windows?('darwin25')
    assert_equal P.windows?(RbConfig::CONFIG['host_os']), P.windows?
  end

  def test_current_is_chosen_once
    assert_instance_of(P.windows? ? P::Windows : P::Posix, P.current)
    saved = P.current
    P.instance_variable_set(:@current, :memoised)
    assert_equal :memoised, P.current
  ensure
    P.instance_variable_set(:@current, saved)
  end

  def test_posix
    x = P::Posix.new
    assert_equal ['posix', ['/bin/sh', '-c', 'rake test'], { pgroup: true }, 'mutaruby-', true],
                 [x.name, x.spawn_args('rake test'), x.spawn_options, x.temp_prefix, x.stop_leftovers?]
  end

  def test_windows
    x = P::Windows.new
    assert_equal ['windows', ['rake test'], { new_pgroup: true }, 'mr', false],
                 [x.name, x.spawn_args('rake test'), x.spawn_options, x.temp_prefix, x.stop_leftovers?]
  end

  def test_windows_stops_the_tree_with_taskkill
    calls = []
    x = P::Windows.new(system: ->(*argv) { calls << argv })
    x.stop_tree(42, graceful: true)
    x.stop_tree(42, graceful: false)
    assert_equal [%w[taskkill /T /PID 42], %w[taskkill /T /F /PID 42]], calls
  end

  # By default taskkill runs through Kernel.system with its output discarded.
  def test_windows_runs_taskkill_quietly
    calls = []
    Kernel.singleton_class.alias_method(:real_system, :system)
    Kernel.define_singleton_method(:system) { |*argv| calls << argv }
    begin
      P::Windows.new.stop_tree(7, graceful: false)
    ensure
      Kernel.singleton_class.alias_method(:system, :real_system)
    end
    assert_equal [['taskkill', '/T', '/F', '/PID', '7', { out: File::NULL, err: File::NULL }]], calls
  end

  def test_windows_liveness_is_the_process
    x = P::Windows.new
    assert x.alive?(Process.pid)
    refute x.alive?(dead_pid)
  end

  def test_posix_liveness_is_the_process_group
    posix_only!
    x = P::Posix.new
    assert x.alive?(Process.getpgrp)
    refute x.alive?(dead_pid)
  end

  def test_posix_stops_the_group
    posix_only!
    x = P::Posix.new
    %i[graceful forced].each do |how|
      pid = Process.spawn('sleep 30', pgroup: true)
      x.stop_tree(pid, graceful: how == :graceful)
      _, st = Process.wait2(pid)
      assert_equal(how == :graceful ? 'TERM' : 'KILL', Signal.signame(st.termsig))
      assert_nil x.stop_tree(pid, graceful: true), 'a group that is gone is not an error'
    end
  end
end
