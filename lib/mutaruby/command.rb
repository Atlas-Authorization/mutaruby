# frozen_string_literal: true

require 'tempfile'
require_relative 'platform'

module Mutaruby
  # Runs the user's test command once, in a fresh process (a new shell and everything it starts), inside a sandbox.
  # Exit status 0 means the tests passed. A run that exceeds the timeout is killed together with its whole process group.
  class Command
    Result = Struct.new(:status, :exitstatus, :seconds, :output, keyword_init: true) do
      def passed? = status == :passed
      def timeout? = status == :timeout
    end

    OUTPUT_TAIL = 4000
    # After SIGTERM, a process group gets this many seconds to exit before SIGKILL.
    KILL_GRACE = 2
    POLL = 0.05

    def initialize(command, root:, kill_grace: KILL_GRACE, platform: Platform.current)
      @command = command
      @platform = platform
      @kill_grace = kill_grace
      @root = File.expand_path(root)
      @live = {} # pid => the thread reaping it
      @lock = Mutex.new
    end

    # Kills every run still in progress (used when mutaruby itself is interrupted: the runs live in their own process
    # groups, so a Ctrl-C in the terminal does not reach them).
    def kill_all
      @lock.synchronize { @live.each { |pid, waiter| kill_group(pid, waiter) } }
    end

    # dir: sandbox project dir. timeout: seconds (nil = none). capture: keep an output tail (for the baseline report).
    def run(dir, timeout: nil, env: {}, capture: false)
      return execute(dir, timeout, env, File::NULL) unless capture

      Tempfile.create do |log|
        result = execute(dir, timeout, env, log)
        log.rewind
        result.output = tail(log.read)
        result
      end
    end

    private

    def execute(dir, timeout, env, out)
      started = monotonic
      pid = Process.spawn(child_env(dir).merge(env), *@platform.spawn_args(@command),
                          chdir: dir, in: File::NULL, out: out, err: out, **@platform.spawn_options)
      waiter = Process.detach(pid)
      @lock.synchronize { @live[pid] = waiter }
      timed_out = waiter.join(timeout).nil?
      # A timed-out run, and (where the platform allows) anything a finished run left behind, must not outlive it.
      kill_group(pid, waiter) if timed_out || @platform.stop_leftovers?
      st = waiter.value
      @lock.synchronize { @live.delete(pid) }
      status = if timed_out then :timeout
               elsif st.success? then :passed
               else :failed
               end
      Result.new(status: status, exitstatus: st.exitstatus, seconds: monotonic - started)
    end

    # Bundler exports the ORIGINAL Gemfile path to child processes. Left as is, `bundle exec` in the sandbox would
    # resolve the Gemfile (and a `gemspec` line's lib/ directory) from the user's checkout and test the unmutated code.
    # The per-mutant variables are always set or cleared explicitly, so a mutaruby run nested inside another one's
    # test command does not inherit the outer run's values.
    def child_env(dir)
      env = { 'MUTARUBY' => '1', 'MUTARUBY_MUTANT_ID' => nil, 'MUTARUBY_FILE' => nil }
      %w[BUNDLE_GEMFILE BUNDLE_APP_CONFIG].each do |k|
        v = ENV.fetch(k, nil)
        next unless v

        full = File.expand_path(v)
        env[k] = full.start_with?("#{@root}/") ? File.join(dir, full.delete_prefix("#{@root}/")) : v
      end
      env
    end

    # Stop the whole tree gracefully, give it up to kill_grace seconds, then force it.
    def kill_group(pid, waiter)
      @platform.stop_tree(pid, graceful: true)
      deadline = monotonic + @kill_grace
      sleep POLL while monotonic < deadline && @platform.alive?(pid, waiter)
      @platform.stop_tree(pid, graceful: false)
    end

    def tail(bytes)
      bytes.byteslice([bytes.bytesize - OUTPUT_TAIL, 0].max..).force_encoding(Encoding::UTF_8).scrub
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
