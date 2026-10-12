# frozen_string_literal: true

require 'optparse'
require 'etc'

module Mutaruby
  # Command line interface. Exit status: 0 success, 1 score below --fail-under (or stale ignore entries with
  # --strict-ignore), 2 usage error, unparsable ignore file or failing baseline.
  class CLI
    EXIT_OK = 0
    EXIT_FAIL = 1
    EXIT_ERROR = 2

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @o = Runner::Options.new(jobs: Etc.nprocessors, patterns: [], methods: [], exclude_methods: [], lines: [],
                               exclude_lines: [], copy_excludes: [], progress: true)
      @include_ops = []
      @exclude_ops = []
    end

    def run
      catch(:done) { return execute }
      EXIT_OK # --help / --version
    end

    private

    def execute
      parser.parse!(@argv)
      @o.patterns = @argv
      return list_operators if @list_operators

      @o.operators = operators
      raise Error, 'missing --test COMMAND (the command that runs your tests; exit 0 = pass)' if @o.command.nil? && !@list

      runner = Runner.new(@o, out: @stderr)
      return list(runner.plan) if @list

      report = runner.run
      emit(report)
      status(report)
    rescue OptionParser::ParseError, Error, IgnoreFile::Invalid, SpliceError => e
      @stderr.puts "mutaruby: #{e.message}"
      EXIT_ERROR
    rescue Interrupt
      @stderr.puts "\nmutaruby: interrupted"
      130
    end

    def parser
      OptionParser.new do |o|
        o.banner = 'Usage: mutaruby --test COMMAND [options] [FILE|GLOB ...]   (default: lib/**/*.rb)'
        o.separator ''
        o.separator 'Test oracle:'
        o.on('-t', '--test COMMAND', 'Shell command that runs the tests; exit 0 = mutant survived, non-zero = killed') { |v| @o.command = v }
        o.on('-C', '--root DIR', 'Project root (copied for every worker; default: current directory)') { |v| @o.root = v }
        o.on('-j', '--jobs N', Integer, "Parallel workers (default: #{Etc.nprocessors})") { |v| @o.jobs = v }
        o.on('--timeout SECONDS', Float, 'Per-mutant timeout (default: baseline time x factor + 5s)') { |v| @o.timeout = v }
        o.on('--timeout-factor F', Float, 'Multiplier on the baseline time for the default timeout (default: 3)') { |v| @o.timeout_factor = v }
        o.on('--copy-exclude GLOB', 'Do not copy matching paths into the sandboxes (repeatable; .git and coverage are always skipped)') { |v| @o.copy_excludes << v }
        o.separator ''
        o.separator 'Selection:'
        o.on('--since REF', 'Only files changed since a git ref (committed, staged, unstaged, untracked)') { |v| @o.since = v }
        o.on('--method PATTERN', 'Only mutants inside matching methods ("Calc#add", "Calc#*", "add"; repeatable)') { |v| @o.methods << v }
        o.on('--exclude-method PATTERN', 'Skip mutants inside matching methods (repeatable)') { |v| @o.exclude_methods << v }
        o.on('--line SPEC', 'Only mutants on these lines: [FILE:]LINE or [FILE:]FROM-TO (repeatable)') { |v| @o.lines << Selection.parse_line_spec(v) }
        o.on('--exclude-line SPEC', 'Skip mutants on these lines (repeatable)') { |v| @o.exclude_lines << Selection.parse_line_spec(v) }
        o.on('--operators LIST', Array, 'Only these operators (comma-separated; globs allowed, e.g. condition-*)') { |v| @include_ops.concat(v) }
        o.on('--exclude-operators LIST', Array, 'Skip these operators (comma-separated; globs allowed)') { |v| @exclude_ops.concat(v) }
        o.on('--shard I/N', 'Run only shard I of N (1-based) of the selected mutants') { |v| @o.shard = Selection.parse_shard(v) }
        o.separator ''
        o.separator 'Equivalent mutants:'
        o.on('--ignore-file PATH', 'Ignore file (default: .mutaruby-ignore.yml in the root, if present)') { |v| @o.ignore_file = v }
        o.on('--strict-ignore', 'Fail (exit 1) when an ignore entry matches no surviving mutant') { @strict = true }
        o.on('--suggest-ignore', 'Print ignore-file stubs for the surviving mutants (fill in each reason)') { @suggest = true }
        o.separator ''
        o.separator 'Output:'
        o.on('--json PATH', 'Write a JSON report ("-" = stdout)') { |v| @json = v }
        o.on('--junit PATH', 'Write a JUnit-style XML report ("-" = stdout)') { |v| @junit = v }
        o.on('--fail-under PERCENT', Float, 'Exit 1 when the mutation score is below PERCENT') { |v| @fail_under = v }
        o.on('--list', 'List the selected mutants without running anything') { @list = true }
        o.on('--list-operators', 'List the mutation operators') { @list_operators = true }
        o.on('-q', '--quiet', 'No progress marks') { @o.progress = false }
        o.on('-v', '--verbose', 'Also list timeouts and equivalent mutants') { @verbose = true }
        o.on('--version', 'Print the version') do
          @stdout.puts "mutaruby #{VERSION}"
          throw :done
        end
        o.on('-h', '--help', 'Show this help') do
          @stdout.puts o
          throw :done
        end
      end
    end

    private

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
      human_io = [@json, @junit].include?('-') ? @stderr : @stdout
      Reporters.human(report, human_io, verbose: @verbose)
      write(@json) { |io| Reporters.json(report, io) } if @json
      write(@junit) { |io| Reporters.junit(report, io) } if @junit
      return unless @suggest

      survivors = report.outcomes.select { |o| o.status == :survived }.map(&:mutation)
      @stderr.puts '# ignore-file stubs (add a reason to each; keep only true equivalents):'
      @stderr.puts IgnoreFile.stub_for(survivors, report.sources) if survivors.any?
    end

    def write(path, &block)
      if path == '-'
        block.call(@stdout)
      else
        File.open(path, 'w', &block)
      end
    end

    def status(report)
      code = EXIT_OK
      if @fail_under && (report.score || 100.0) < @fail_under
        @stderr.puts format('mutaruby: score %s is below --fail-under %.2f%%', Reporters.score_text(report), @fail_under)
        code = EXIT_FAIL
      end
      if @strict && report.stale.any?
        @stderr.puts "mutaruby: #{report.stale.size} stale ignore entr#{report.stale.size == 1 ? 'y' : 'ies'} (--strict-ignore)"
        code = EXIT_FAIL
      end
      code
    end
  end
end
