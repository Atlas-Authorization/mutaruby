# frozen_string_literal: true

require 'open3'
require_relative 'error'

module Mutaruby
  # Which files to mutate and which of their mutants to run.
  class Selection
    DEFAULT_PATTERNS = ['lib/**/*.rb'].freeze

    LineSpec = Struct.new(:file, :from, :to) do
      def cover?(mutation)
        (file.nil? || file == mutation.file) && mutation.lineno.between?(from, to)
      end
    end

    def self.parse_line_spec(spec)
      m = spec.match(/\A(?:(.+):)?(\d+)(?:-(\d+))?\z/)
      raise Error, "bad line spec #{spec.inspect} (expected [FILE:]LINE or [FILE:]FROM-TO)" unless m

      from = m[2].to_i
      to = (m[3] || m[2]).to_i
      raise Error, "bad line spec #{spec.inspect} (FROM > TO)" if from > to

      LineSpec.new(m[1]&.delete_prefix('./'), from, to)
    end

    def self.parse_shard(spec)
      i, n = spec.match(%r{\A(\d+)/(\d+)\z})&.captures&.map(&:to_i)
      raise Error, "bad --shard #{spec.inspect} (expected I/N, 1 <= I <= N)" unless i&.between?(1, n)

      [i, n]
    end

    # lines / exclude_lines: LineSpec objects (see parse_line_spec). shard: [i, n] or nil.
    def initialize(root:, patterns: [], since: nil, methods: [], exclude_methods: [], lines: [], exclude_lines: [],
                   shard: nil, subjects: [])
      @root = File.expand_path(root)
      @patterns = patterns.empty? ? DEFAULT_PATTERNS : patterns
      @since = since
      @methods = methods
      @exclude_methods = exclude_methods
      @lines = lines
      @exclude_lines = exclude_lines
      @shard = shard
      @subjects = subjects
    end

    # True when every mutant of each selected file is run (so stale ignore entries can be detected).
    def complete?
      @methods.empty? && @exclude_methods.empty? && @lines.empty? && @exclude_lines.empty? && @shard.nil? &&
        @subjects.empty?
    end

    # Sorted paths of the matching files, relative to the root.
    def files
      found = @patterns.flat_map { |pat| Dir.glob(pat, base: @root) }.map do |f|
        full = File.expand_path(f, @root)
        raise Error, "#{f} is outside the project root #{@root}" unless full.start_with?("#{@root}/")

        full.delete_prefix("#{@root}/")
      end
      found = found.select { |f| File.file?(File.join(@root, f)) }.uniq.sort
      @since ? found & changed_files : found
    end

    def filter(mutations)
      kept = mutations.select do |m|
        (@subjects.empty? || @subjects.any? { |s| subject_match?(s, m.method) }) &&
          (@methods.empty? || @methods.any? { |p| method_match?(p, m.method) }) &&
          @exclude_methods.none? { |p| method_match?(p, m.method) } &&
          (@lines.empty? || @lines.any? { |s| s.cover?(m) }) &&
          @exclude_lines.none? { |s| s.cover?(m) }
      end
      return kept unless @shard

      i, n = @shard
      kept.select.with_index { |_, idx| idx % n == i - 1 }
    end

    private

    # A pattern matches the qualified name ("Calc#add", "Calc.build", "Calc#*") or the bare method name ("add").
    # Code outside any method matches no pattern.
    def method_match?(pattern, name)
      name ? File.fnmatch?(pattern, name) || File.fnmatch?(pattern, name.split(/[#.]/).last) : false
    end

    # A subject names methods by their place in the code:
    #   "Foo#bar", "Foo.bar"      one method (instance, singleton); globs allowed: "Foo#*", "Foo.*", "Foo#to_*"
    #   "Foo", "Foo::Bar"         every method of that namespace and of the namespaces nested in it
    #   "Foo*"                    a glob over namespaces ("Foo*" matches Foo, FooBar and Foo::Baz)
    def subject_match?(subject, name)
      name ? subject_name_match?(subject, name) : false
    end

    def subject_name_match?(subject, name)
      return File.fnmatch?(subject, name) if subject.match?(/[#.]/)

      namespace = name.split(/[#.]/).first
      namespace.start_with?("#{subject}::") || File.fnmatch?(subject, namespace)
    end

    # Files changed relative to a git ref: committed, staged and unstaged edits, plus new untracked files.
    def changed_files
      git('diff', '--name-only', '--relative', @since, '--') + git('ls-files', '--others', '--exclude-standard')
    end

    def git(*args)
      out, err, st = Open3.capture3('git', '-C', @root, *args)
      raise Error, "git #{args.join(' ')} failed: #{err.strip}" unless st.success?

      out.lines(chomp: true)
    end
  end
end
