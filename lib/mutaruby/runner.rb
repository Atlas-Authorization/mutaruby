# frozen_string_literal: true

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
                         :progress, keyword_init: true) do
      def self.build(**kw)
        new(root: '.', patterns: [], jobs: 1, timeout_factor: 3.0, methods: [], exclude_methods: [], lines: [],
            exclude_lines: [], copy_excludes: [], progress: false, **kw)
      end
    end

    MARK = { killed: '.', timeout: 'T', survived: 'S', equivalent: 'e' }.freeze

    def initialize(opts, out: $stderr)
      @o = opts
      @out = out
      @root = File.expand_path(opts.root)
    end

    # Mutants of the selected files after every filter, plus what is needed to report them.
    def plan
      sel = selection
      files = sel.files
      sources = files.to_h { |f| [f, File.read(File.join(@root, f), encoding: 'UTF-8')] }
      warnings = []
      all = files.flat_map do |f|
        g = Generator.new(sources[f], path: File.join(@root, f), rel: f, operators: @o.operators)
        ms = g.mutations
        warnings.concat(g.errors)
        ms
      end
      all.each_with_index { |m, i| m.id = i }
      ignore = load_ignore
      errs = ignore ? ignore.validate(sources) : []
      raise Error, "ignore file #{ignore.path}:\n  #{errs.join("\n  ")}" if errs.any?

      { files: files, sources: sources, mutations: sel.filter(all), ignore: ignore, warnings: warnings,
        complete: sel.complete? && @o.operators.nil? }
    end

    def run
      sandboxes = []
      cmd = Command.new(@o.command, root: @root)
      t0 = monotonic
      p = plan
      first = Sandbox.new(@root, excludes: @o.copy_excludes)
      sandboxes << first
      base = cmd.run(first.dir, capture: true)
      unless base.passed?
        raise BaselineFailed, "the test command fails on the UNMUTATED code (exit #{base.exitstatus}); every mutant " \
                              "would count as killed, so nothing would be measured.\ncommand: #{@o.command}\n" \
                              "--- output (tail) ---\n#{base.output}"
      end
      timeout = @o.timeout || ((base.seconds * @o.timeout_factor) + 5).ceil
      outcomes = execute(p, cmd, sandboxes, timeout)
      matched = outcomes.select { |o| o.status == :equivalent }.map(&:ignore)
      stale = p[:ignore] && p[:complete] ? p[:ignore].stale(matched, p[:files]) : []
      Report.new(root: @root, command: @o.command, files: p[:files], outcomes: outcomes, sources: p[:sources],
                 stale: stale, warnings: p[:warnings], baseline_seconds: base.seconds, timeout: timeout,
                 jobs: jobs, seconds: monotonic - t0, complete: p[:complete])
    rescue Interrupt
      cmd.kill_all
      raise
    ensure
      sandboxes.each(&:cleanup)
    end

    private

    def jobs
      [@o.jobs, 1].max
    end

    def selection
      Selection.new(root: @root, patterns: @o.patterns, since: @o.since, methods: @o.methods,
                    exclude_methods: @o.exclude_methods, lines: @o.lines, exclude_lines: @o.exclude_lines,
                    shard: @o.shard)
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
      sandboxes << Sandbox.new(@root, excludes: @o.copy_excludes) while sandboxes.size < n
      results = []
      lock = Mutex.new
      threads = sandboxes.map do |box|
        Thread.new do
          while (m = next_mutation(queue))
            o = evaluate(m, box, plan, cmd, timeout)
            lock.synchronize do
              results << o
              progress(o)
            end
          end
        end
      end
      begin
        threads.each(&:join)
      rescue Interrupt
        threads.each(&:kill)
        raise
      end
      @out.puts if @o.progress && results.any?
      results.sort_by { |o| o.mutation.id }
    end

    def next_mutation(queue)
      queue.pop(true)
    rescue ThreadError
      nil
    end

    def evaluate(m, box, plan, cmd, timeout)
      r = box.with_file(m.file, m.text, plan[:sources][m.file]) do
        cmd.run(box.dir, timeout: timeout, env: { 'MUTARUBY_MUTANT_ID' => m.id.to_s, 'MUTARUBY_FILE' => m.file })
      end
      entry = plan[:ignore]&.match(m)
      status = if r.timeout? then :timeout
               elsif !r.passed? then :killed
               elsif entry then :equivalent
               else :survived
               end
      Outcome.new(mutation: m, status: status, seconds: r.seconds, ignore: entry)
    end

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
