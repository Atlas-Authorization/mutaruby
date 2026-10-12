# frozen_string_literal: true

require 'set'
require_relative 'generator'
require_relative 'ignore_file'
require_relative 'sandbox'
require_relative 'command'
require_relative 'selection'

module Mutaruby
  class BaselineFailed < Error; end

  # Generates the mutants, checks the baseline, runs every mutant and collects the verdicts.
  class Runner
    Outcome = Struct.new(:mutation, :status, :seconds, :ignore, keyword_init: true) do
      # :killed, :timeout (also a kill), :survived, :equivalent (survived, listed in the ignore file)
      def killed? = %i[killed timeout].include?(status)
    end

    Report = Struct.new(:root, :command, :files, :outcomes, :sources, :stale, :warnings, :baseline_seconds, :timeout,
                        :jobs, :seconds, :complete, keyword_init: true) do
      def count(status) = outcomes.count { |o| o.status == status }
      def killed = count(:killed) + count(:timeout)

      # killed / (killed + survived); equivalents are left out of both. nil when nothing was scored.
      def score
        scored = killed + count(:survived)
        scored.zero? ? nil : (100.0 * killed / scored)
      end
    end

    Options = Struct.new(:root, :command, :patterns, :since, :jobs, :timeout, :timeout_factor, :methods,
                         :exclude_methods, :lines, :exclude_lines, :shard, :ignore_file, :operators, :copy_excludes,
                         :progress, :keyword_init => true)

    def initialize(opts, out: $stderr)
      @o = opts
      @out = out
      @root = File.expand_path(opts.root || Dir.pwd)
      @warnings = []
    end

    # Mutants of the selected files after every filter, plus what is needed to report them.
    def plan
      @plan ||= begin
        sel = selection
        files = sel.files
        sources = files.to_h { |f| [f, File.read(File.join(@root, f), encoding: 'UTF-8')] }
        all = files.flat_map do |f|
          g = Generator.new(sources[f], path: File.join(@root, f), rel: f, operators: operator_set)
          ms = g.mutations
          @warnings.concat(g.errors)
          ms
        end
        all.each_with_index { |m, i| m.id = i }
        ignore = load_ignore
        if ignore
          errs = ignore.validate(sources)
          raise Error, "ignore file #{ignore.path}:\n  #{errs.join("\n  ")}" if errs.any?
        end
        { files: files, sources: sources, mutations: sel.filter(all), ignore: ignore, complete: sel.complete? && @o.operators.nil? }
      end
    end

    def run
      t0 = monotonic
      p = plan
      sandboxes = []
      sandboxes << Sandbox.new(@root, excludes: @o.copy_excludes || [])
      cmd = Command.new(@o.command, root: @root)
      base = cmd.run(sandboxes[0].dir, capture: true)
      unless base.passed?
        raise BaselineFailed, "the test command fails on the UNMUTATED code (#{base.timeout? ? 'timed out' : "exit #{base.exitstatus}"}); " \
                              "every mutant would count as killed, so nothing would be measured.\n" \
                              "command: #{@o.command}\n--- output (tail) ---\n#{base.output}"
      end
      timeout = @o.timeout || ((base.seconds * (@o.timeout_factor || 3.0)) + 5).ceil
      outcomes = execute(p, cmd, sandboxes, timeout)
      stale = []
      if p[:ignore]
        matched = outcomes.select { |o| o.status == :equivalent }.map(&:ignore).to_set
        stale = p[:complete] ? p[:ignore].stale(matched, p[:files]) : []
      end
      Report.new(root: @root, command: @o.command, files: p[:files], outcomes: outcomes, sources: p[:sources],
                 stale: stale, warnings: @warnings, baseline_seconds: base.seconds, timeout: timeout,
                 jobs: jobs, seconds: monotonic - t0, complete: p[:complete])
    rescue Interrupt, SignalException
      cmd&.kill_all
      raise
    ensure
      sandboxes&.each(&:cleanup)
    end

    private

    def jobs
      [@o.jobs || 1, 1].max
    end

    def selection
      Selection.new(root: @root, patterns: @o.patterns || [], since: @o.since, methods: @o.methods || [],
                    exclude_methods: @o.exclude_methods || [], lines: @o.lines || [],
                    exclude_lines: @o.exclude_lines || [], shard: @o.shard)
    end

    def operator_set
      return nil unless @o.operators

      @o.operators.to_set
    end

    def load_ignore
      path = @o.ignore_file
      default = File.join(@root, '.mutaruby-ignore.yml')
      path ||= default if File.exist?(default)
      return nil unless path

      raise Error, "ignore file not found: #{path}" unless File.exist?(path)

      IgnoreFile.load(path)
    end

    def execute(plan, cmd, sandboxes, timeout)
      queue = Queue.new
      plan[:mutations].each { |m| queue << m }
      n = [jobs, plan[:mutations].size].min
      (sandboxes.size...n).each { sandboxes << Sandbox.new(@root, excludes: @o.copy_excludes || []) }
      results = []
      lock = Mutex.new
      threads = Array.new(n) do |w|
        Thread.new do
          box = sandboxes[w]
          loop do
            m = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            original = plan[:sources][m.file]
            r = box.with_file(m.file, m.text, original) do
              cmd.run(box.dir, timeout: timeout,
                               env: { 'MUTARUBY_MUTANT_ID' => m.id.to_s, 'MUTARUBY_FILE' => m.file })
            end
            entry = plan[:ignore]&.match(m)
            status = if r.timeout? then :timeout
                     elsif !r.passed? then :killed
                     elsif entry then :equivalent
                     else :survived
                     end
            o = Outcome.new(mutation: m, status: status, seconds: r.seconds, ignore: entry)
            lock.synchronize do
              results << o
              progress(o)
            end
          end
        end
      end
      begin
        threads.each(&:join)
      rescue Exception # rubocop:disable Lint/RescueException -- stop the workers, then re-raise
        threads.each(&:kill)
        raise
      end
      @out.puts if @o.progress && results.any?
      results.sort_by { |o| o.mutation.id }
    end

    MARK = { killed: '.', timeout: 'T', survived: 'S', equivalent: 'e' }.freeze

    def progress(outcome)
      return unless @o.progress

      @out.print(MARK[outcome.status])
      @out.flush
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
