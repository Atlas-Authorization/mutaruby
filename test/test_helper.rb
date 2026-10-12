# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mutaruby'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'rbconfig'

module TestHelpers
  RUBY = %("#{RbConfig.ruby}" --disable-gems)
  SCRIPTS = Dir.mktmpdir('tscripts')
  Minitest.after_run { FileUtils.rm_rf(SCRIPTS) }

  # A test command that runs `code` with Ruby: portable between /bin/sh and cmd.exe, whose quoting rules differ.
  def rb(code)
    path = File.join(SCRIPTS, "c#{code.unpack1('H*')[0, 40]}#{code.sum}#{code.size}.rb")
    File.write(path, code)
    %(#{RUBY} "#{path}")
  end

  # A test command that fails (kills the mutant) when `file` contains `text`.
  def kill_if(text, file = 'lib/a.rb')
    rb("exit(File.read(#{file.inspect}).include?(#{text.inspect}) ? 1 : 0)")
  end

  def windows? = Mutaruby::Platform.windows?

  def posix_only!
    skip 'POSIX only' if windows?
  end

  def sandbox_prefix = Mutaruby::Platform.current.temp_prefix

  # True when no process with this id runs (on Windows signal 0 is not reliable for this, so ask tasklist).
  def process_gone?(pid)
    return !IO.popen(['tasklist', '/FI', "PID eq #{pid}", '/NH'], &:read).include?(" #{pid} ") if windows?

    Process.kill(0, pid)
    false
  rescue Errno::ESRCH
    true
  end

  # A per-mutant timeout for tests where one mutant hangs: long enough for a normal run to finish even on a slow
  # Windows runner (Ruby starts much more slowly there).
  def hang_timeout = windows? ? 6 : 1

  # Mutants of a snippet as [operator, orig, repl] triples.
  def muts(src, operators: nil)
    Mutaruby::Generator.new(src, path: 'snippet.rb', operators: operators&.to_set).mutations
  end

  def triples(src, operators: nil)
    muts(src, operators: operators).map { |m| [m.operator, m.orig, m.repl] }
  end

  def changes(src, op)
    muts(src, operators: [op]).map(&:change)
  end

  # Builds a throwaway project: { "lib/a.rb" => "..." }. Yields the root and removes it afterwards.
  def with_project(files)
    Dir.mktmpdir('tproj-') do |dir|
      root = File.join(dir, 'proj')
      files.each do |rel, body|
        path = File.join(root, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, body)
      end
      yield root
    end
  end

  # Sets (or, with nil, removes) environment variables for the block and restores them afterwards.
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def options(**kw)
    Mutaruby::Runner::Options.build(jobs: 2, **kw)
  end

  def snapshot(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.reject { |f| File.directory?(File.join(root, f)) }
       .to_h { |f| [f, File.binread(File.join(root, f))] }
  end
end

# CI watchdog (TEST_WATCHDOG=SECONDS): if one test runs longer than that, print its name and every thread's
# backtrace, then exit, so a hang shows where it is instead of running into the job timeout.
if (limit = ENV['TEST_WATCHDOG']&.to_f)
  module TestWatchdog
    def before_setup
      $watchdog_test = [name, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
      super
    end
  end
  Minitest::Test.prepend(TestWatchdog)
  Thread.new do
    loop do
      sleep 1
      test, started = $watchdog_test
      next unless test && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > limit

      warn "WATCHDOG: #{test} has run for more than #{limit}s"
      Thread.list.each { |t| warn "#{t.inspect}\n  #{(t.backtrace || []).first(20).join("\n  ")}" }
      exit!(3)
    end
  end
end
