# frozen_string_literal: true

require 'optparse'
require 'etc'
require_relative 'runner'
require_relative 'reporters'

module Mutaruby
  # Command line interface. Exit status: 0 success, 1 score below --fail-under (or stale ignore entries with
  # --strict-ignore), 2 usage error, unparsable ignore file or failing baseline.
  class CLI
    EXIT_OK = 0
    EXIT_FAIL = 1
    EXIT_ERROR = 2
    EXIT_INTERRUPTED = 130

    attr_reader :options, :flags

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @options = Runner::Options.build(jobs: Etc.nprocessors, progress: true)
      @flags = {}
      @include_ops = []
      @exclude_ops = []
    end

    def run
      catch(:done) { return execute }
      EXIT_OK # --help / --version
    end

    # Parses the arguments into `options` (and `flags`); the remaining arguments are the file patterns.
    def parse
      parser.parse!(@argv)
      @options.patterns = @argv
      @options.operators = operators
      self
    end

    private

    def execute
      parse
      return list_operators if @flags[:list_operators]

      runner = Runner.new(@options, out: @stderr)
      return list(runner.plan) if @flags[:list]
      raise Error, 'missing --test COMMAND (the command that runs your tests; exit 0 = pass)' unless @options.command

      report = runner.run
      emit(report)
      status(report)
    rescue OptionParser::ParseError, Error, IgnoreFile::Invalid, SpliceError => e
      @stderr.puts "mutaruby: #{e}"
      EXIT_ERROR
    rescue Interrupt
      @stderr.puts "\nmutaruby: interrupted"
      EXIT_INTERRUPTED
    end

    def parser
      o = @options
      OptionParser.new do |op|
        op.banner = 'Usage: mutaruby --test COMMAND [options] [FILE|GLOB ...]   (default: lib/**/*.rb)'
        op.separator ''
        op.separator 'Test oracle:'
        op.on('-t', '--test COMMAND', 'Shell command that runs the tests; exit 0 = mutant survived, non-zero = killed') { |v| o.command = v }
        op.on('-C', '--root DIR', 'Project root (copied for every worker; default: current directory)') { |v| o.root = v }
        op.on('-j', '--jobs N', Integer, "Parallel workers (default: #{Etc.nprocessors})") { |v| o.jobs = v }
        op.on('--timeout SECONDS', Float, 'Per-mutant timeout (default: baseline time x factor + 5s)') { |v| o.timeout = v }
        op.on('--timeout-factor F', Float, 'Multiplier on the baseline time for the default timeout (default: 3)') { |v| o.timeout_factor = v }
        op.on('--copy-exclude GLOB', 'Do not copy matching paths into the sandboxes (repeatable; .git and coverage are always skipped)') { |v| o.copy_excludes += [v] }
        op.separator ''
        op.separator 'Selection:'
        op.on('--since REF', 'Only files changed since a git ref (committed, staged, unstaged, untracked)') { |v| o.since = v }
        op.on('--method PATTERN', 'Only mutants inside matching methods ("Calc#add", "Calc#*", "add"; repeatable)') { |v| o.methods += [v] }
        op.on('--exclude-method PATTERN', 'Skip mutants inside matching methods (repeatable)') { |v| o.exclude_methods += [v] }
        op.on('--line SPEC', 'Only mutants on these lines: [FILE:]LINE or [FILE:]FROM-TO (repeatable)') { |v| o.lines += [Selection.parse_line_spec(v)] }
        op.on('--exclude-line SPEC', 'Skip mutants on these lines (repeatable)') { |v| o.exclude_lines += [Selection.parse_line_spec(v)] }
        op.on('--operators LIST', Array, 'Only these operators (comma-separated; globs allowed, e.g. condition-*)') { |v| @include_ops += v }
        op.on('--exclude-operators LIST', Array, 'Skip these operators (comma-separated; globs allowed)') { |v| @exclude_ops += v }
        op.on('--shard I/N', 'Run only shard I of N (1-based) of the selected mutants') { |v| o.shard = Selection.parse_shard(v) }
        op.separator ''
        op.separator 'Equivalent mutants:'
        op.on('--ignore-file PATH', 'Ignore file (default: .mutaruby-ignore.yml in the root, if present)') { |v| o.ignore_file = v }
        op.on('--strict-ignore', 'Fail (exit 1) when an ignore entry matches no surviving mutant') { @flags[:strict] = true }
        op.on('--suggest-ignore', 'Print ignore-file stubs for the surviving mutants (fill in each reason)') { @flags[:suggest] = true }
        op.separator ''
        op.separator 'Output:'
        op.on('--json PATH', 'Write a JSON report ("-" = stdout)') { |v| @flags[:json] = v }
        op.on('--junit PATH', 'Write a JUnit-style XML report ("-" = stdout)') { |v| @flags[:junit] = v }
        op.on('--fail-under PERCENT', Float, 'Exit 1 when the mutation score is below PERCENT') { |v| @flags[:fail_under] = v }
        op.on('--list', 'List the selected mutants without running anything') { @flags[:list] = true }
        op.on('--list-operators', 'List the mutation operators') { @flags[:list_operators] = true }
        op.on('-q', '--quiet', 'No progress marks') { o.progress = false }
        op.on('-v', '--verbose', 'Also list timeouts and equivalent mutants') { @flags[:verbose] = true }
        op.on('--version', 'Print the version') do
          @stdout.puts "mutaruby #{VERSION}"
          throw :done
        end
        op.on('-h', '--help', 'Show this help') do
          @stdout.puts op
          throw :done
        end
      end
    end

    # nil (every operator) unless --operators / --exclude-operators narrowed the set.
    def operators
      return nil if @include_ops.empty? && @exclude_ops.empty?

      all = Generator::OPERATORS.keys
      (@include_ops + @exclude_ops).each do |pat|
        raise Error, "unknown operator #{pat.inspect} (see --list-operators)" if all.none? { |id| File.fnmatch?(pat, id) }
      end
      chosen = @include_ops.empty? ? all : all.select { |id| @include_ops.any? { |p| File.fnmatch?(p, id) } }
      chosen.reject { |id| @exclude_ops.any? { |p| File.fnmatch?(p, id) } }
    end

    def list_operators
      w = Generator::OPERATORS.keys.map(&:size).max
      Generator::OPERATORS.each { |id, d| @stdout.puts "#{id.ljust(w)}  #{d}" }
      EXIT_OK
    end

    def list(plan)
      plan[:mutations].each do |m|
        @stdout.puts "#{m.id}\t#{m.location}\t#{m.method || '-'}\t#{m.label}"
      end
      @stderr.puts "#{plan[:mutations].size} mutants in #{plan[:files].size} files"
      EXIT_OK
    end

    def emit(report)
      human_io = [@flags[:json], @flags[:junit]].include?('-') ? @stderr : @stdout
      Reporters.human(report, human_io, verbose: @flags[:verbose])
      write(@flags[:json]) { |io| Reporters.json(report, io) } if @flags[:json]
      write(@flags[:junit]) { |io| Reporters.junit(report, io) } if @flags[:junit]
      survivors = report.outcomes.select { |o| o.status == :survived }.map(&:mutation)
      return unless @flags[:suggest] && survivors.any?

      @stderr.puts '# ignore-file stubs (add a reason to each; keep only true equivalents):'
      @stderr.puts IgnoreFile.stub_for(survivors, report.sources)
    end

    def write(path, &block)
      path == '-' ? block.call(@stdout) : File.open(path, 'w', &block)
    end

    def status(report)
      code = EXIT_OK
      score = report.score
      if @flags[:fail_under] && score && score < @flags[:fail_under]
        @stderr.puts format('mutaruby: score %s is below --fail-under %.2f%%', Reporters.score_text(report), @flags[:fail_under])
        code = EXIT_FAIL
      end
      n = report.stale.size
      if @flags[:strict] && n.positive?
        @stderr.puts "mutaruby: #{n} stale ignore entr#{n == 1 ? 'y' : 'ies'} (--strict-ignore)"
        code = EXIT_FAIL
      end
      code
    end
  end
end
