# frozen_string_literal: true

require_relative 'ignore_file'
require_relative 'sandbox'
require_relative 'command'
require_relative 'selection'
require_relative 'coverage_map'

module Mutaruby
  class BaselineFailed < Error; end

  # Generates the mutants, checks the baseline, runs every mutant and collects the verdicts.
  class Runner
    # tests: how many tests the mutant ran with coverage-based selection; nil when it ran the whole command.
    Outcome = Struct.new(:mutation, :status, :seconds, :ignore, :tests, keyword_init: true) do
      # :killed, :timeout (also a kill), :survived, :equivalent (survived, listed in the ignore file)
      def killed? = %i[killed timeout].include?(status)
    end

    Report = Struct.new(:root, :command, :files, :outcomes, :sources, :stale, :warnings, :baseline_seconds, :timeout,
                        :jobs, :seconds, :complete, :coverage, keyword_init: true) do
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
                         :progress, :subjects, :coverage, :renderer, keyword_init: true) do
      def self.build(**kw)
        new(root: '.', patterns: [], jobs: 1, timeout_factor: 3.0, methods: [], exclude_methods: [], lines: [],
            exclude_lines: [], copy_excludes: [], progress: false, subjects: [], coverage: false, renderer: :text,
            **kw)
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
      # Bytes as they are (no newline conversion on Windows), read as UTF-8 whatever the default encoding.
      sources = files.to_h { |f| [f, File.binread(File.join(@root, f)).force_encoding(Encoding::UTF_8)] }
      warnings = []
      all = files.flat_map do |f|
        g = Generator.new(sources[f], path: File.join(@root, f), rel: f, operators: @o.operators, renderer: @o.renderer)
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
      coverage_out = first.scratch('coverage.json')
      base_env = @o.coverage ? CoverageMap.probe_env('MUTARUBY_COVERAGE_OUT' => coverage_out,
                                                     'MUTARUBY_COVERAGE_ROOT' => first.dir) : {}
      base = cmd.run(first.dir, capture: true, env: base_env)
      unless base.passed?
        raise BaselineFailed, "the test command fails on the UNMUTATED code (exit #{base.exitstatus}); every mutant " \
                              "would count as killed, so nothing would be measured.\ncommand: #{@o.command}\n" \
                              "--- output (tail) ---\n#{base.output}"
      end
      timeout = @o.timeout || ((base.seconds * @o.timeout_factor) + 5).ceil
      p[:coverage] = coverage_map(coverage_out, p[:warnings]) if @o.coverage
      outcomes = execute(p, cmd, sandboxes, timeout)
      matched = outcomes.select { |o| o.status == :equivalent }.map(&:ignore)
      stale = p[:ignore] && p[:complete] ? p[:ignore].stale(matched, p[:files]) : []
      Report.new(root: @root, command: @o.command, files: p[:files], outcomes: outcomes, sources: p[:sources],
                 stale: stale, warnings: p[:warnings], baseline_seconds: base.seconds, timeout: timeout,
                 jobs: jobs, seconds: monotonic - t0, complete: p[:complete], coverage: p[:coverage]&.framework)
    rescue Interrupt
      # Workers see @stop and start no new mutant; the runs in flight are killed; then the workers finish, before
      # their sandboxes go.
      @stop = true
      cmd.kill_all
      @threads&.each(&:join)
      raise
    ensure
      remove(sandboxes, $!)
    end

    private

    # Removes the sandboxes. When the run is already failing (an interrupt, a failing baseline), a sandbox that cannot
    # be removed is left behind rather than replacing that error: on Windows a process that is still exiting keeps its
    # directory locked for a moment.
    def remove(sandboxes, failing)
      sandboxes.each(&:cleanup)
    rescue SystemCallError
      raise unless failing
    end

    def jobs
      [@o.jobs, 1].max
    end

    def selection
      Selection.new(root: @root, patterns: @o.patterns, since: @o.since, methods: @o.methods,
                    exclude_methods: @o.exclude_methods, lines: @o.lines, exclude_lines: @o.exclude_lines,
                    shard: @o.shard, subjects: @o.subjects)
    end

    # The coverage map recorded by the baseline run, or nil (with a warning) when no supported test framework ran.
    def coverage_map(path, warnings)
      map = File.exist?(path) ? CoverageMap.load(path) : nil
      return map if map&.usable?

      warnings << 'coverage: no Minitest or RSpec tests were recorded in the baseline run; every mutant runs the ' \
                  'whole test command'
      nil
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
      @threads = sandboxes.map do |box|
        Thread.new do
          while !@stop && (m = next_mutation(queue))
            o = evaluate(m, box, plan, cmd, timeout)
            lock.synchronize do
              results << o
              progress(o)
            end
          end
        end
      end
      @threads.each(&:join)
      @out.puts if @o.progress && results.any?
      results.sort_by { |o| o.mutation.id }
    end

    def next_mutation(queue)
      queue.deq(true)
    rescue ThreadError
      nil
    end

    def evaluate(m, box, plan, cmd, timeout)
      env = { 'MUTARUBY_MUTANT_ID' => m.id.to_s, 'MUTARUBY_FILE' => m.file }
      tests = plan[:coverage]&.tests_for(m.file, m.lineno..(m.lineno + m.orig.count("\n")))
      if tests
        list = box.scratch('tests.txt')
        File.write(list, tests.map { |t| "#{t}\n" }.join)
        env.merge!(CoverageMap.probe_env('MUTARUBY_SELECT' => list))
      end
      r = box.with_file(m.file, m.text, plan[:sources][m.file]) { cmd.run(box.dir, timeout: timeout, env: env) }
      entry = plan[:ignore]&.match(m)
      status = if r.timeout? then :timeout
               elsif !r.passed? then :killed
               elsif entry then :equivalent
               else :survived
               end
      Outcome.new(mutation: m, status: status, seconds: r.seconds, ignore: entry, tests: tests&.size)
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
