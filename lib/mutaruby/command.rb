# frozen_string_literal: true

require 'tempfile'

module Mutaruby
  # Runs the user's test command once, in a fresh process (a new shell and everything it starts), inside a sandbox.
  # Exit status 0 means the tests passed. A run that exceeds the timeout is killed together with its whole process group.
  class Command
    Result = Struct.new(:status, :exitstatus, :seconds, :output, keyword_init: true) do
      def passed? = status == :passed
      def timeout? = status == :timeout
    end

    OUTPUT_TAIL = 4000

    def initialize(command, root:, env: {})
      @command = command
      @root = File.expand_path(root)
      @env = env
      @live = {}
      @lock = Mutex.new
    end

    # Kills every run still in progress (used when mutaruby itself is interrupted: the runs live in their own process
    # groups, so a Ctrl-C in the terminal does not reach them).
    def kill_all
      pids = @lock.synchronize { @live.keys }
      pids.each { |pid| kill_group(pid) }
    end

    # dir: sandbox project dir. timeout: seconds (nil = none). capture: keep an output tail (for the baseline report).
    def run(dir, timeout: nil, env: {}, capture: false)
      log = capture ? Tempfile.new('mutaruby-out') : nil
      out = log ? log.path : File::NULL
      started = monotonic
      pid = Process.spawn(child_env(dir).merge(@env).merge(env), '/bin/sh', '-c', @command,
                          chdir: dir, pgroup: true, in: File::NULL, out: out, err: out)
      @lock.synchronize { @live[pid] = true }
      waiter = Process.detach(pid)
      timed_out = waiter.join(timeout).nil? if timeout
      if timed_out
        kill_group(pid)
        waiter.join
      end
      st = waiter.value
      @lock.synchronize { @live.delete(pid) }
      status = if timed_out then :timeout
               elsif st.success? then :passed
               else :failed
               end
      Result.new(status: status, exitstatus: st.exitstatus, seconds: monotonic - started,
                 output: log ? tail(log.path) : nil)
    ensure
      log&.close!
    end

    private

    # Bundler exports the ORIGINAL Gemfile path to child processes. Left as is, `bundle exec` in the sandbox would
    # resolve the Gemfile (and a `gemspec` line's lib/ directory) from the user's checkout and test the unmutated code.
    def child_env(dir)
      # The per-mutant variables are always set or cleared explicitly, so a mutaruby run nested inside another one's
      # test command does not inherit the outer run's mutant id.
      env = { 'MUTARUBY' => '1', 'MUTARUBY_MUTANT_ID' => nil, 'MUTARUBY_FILE' => nil }
      %w[BUNDLE_GEMFILE BUNDLE_APP_CONFIG].each do |k|
        v = ENV.fetch(k, nil)
        next unless v

        full = File.expand_path(v)
        env[k] = full.start_with?("#{@root}/") ? File.join(dir, full.delete_prefix("#{@root}/")) : v
      end
      env
    end

    def kill_group(pid)
      Process.kill('TERM', -pid)
      deadline = monotonic + 2
      sleep 0.05 while monotonic < deadline && alive?(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def tail(path)
      s = File.binread(path)
      s = s[-OUTPUT_TAIL..] if s.bytesize > OUTPUT_TAIL
      s.force_encoding(Encoding::UTF_8).scrub
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
