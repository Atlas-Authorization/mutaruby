# frozen_string_literal: true

require 'open3'

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

      LineSpec.new(m[1]&.sub(%r{\A\./}, ''), from, to)
    end

    def self.parse_shard(spec)
      m = spec.to_s.match(%r{\A(\d+)/(\d+)\z})
      raise Error, "bad --shard #{spec.inspect} (expected I/N, 1 <= I <= N)" unless m && m[2].to_i.positive? && m[1].to_i.between?(1, m[2].to_i)

      [m[1].to_i, m[2].to_i]
    end

    def initialize(root:, patterns: [], since: nil, methods: [], exclude_methods: [], lines: [], exclude_lines: [],
                   shard: nil)
      @root = File.expand_path(root)
      @patterns = patterns.empty? ? DEFAULT_PATTERNS : patterns
      @since = since
      @methods = methods
      @exclude_methods = exclude_methods
      @lines = lines.map { |s| s.is_a?(LineSpec) ? s : self.class.parse_line_spec(s) }
      @exclude_lines = exclude_lines.map { |s| s.is_a?(LineSpec) ? s : self.class.parse_line_spec(s) }
      @shard = shard
    end

    # True when every mutant of each selected file is run (so stale ignore entries can be detected).
    def complete?
      @methods.empty? && @exclude_methods.empty? && @lines.empty? && @exclude_lines.empty? && @shard.nil?
    end

    # Sorted paths relative to the root.
    def files
      found = @patterns.flat_map do |pat|
        full = File.expand_path(pat, @root)
        if File.file?(full)
          [relative(full)]
        else
          Dir.glob(pat, base: @root).select { |f| File.file?(File.join(@root, f)) }
        end
      end
      found = found.map { |f| f.sub(%r{\A\./}, '') }.uniq.sort
      found &= changed_files if @since
      found
    end

    def filter(mutations)
      kept = mutations.select do |m|
        (@methods.empty? || @methods.any? { |p| method_match?(p, m.method) }) &&
          @exclude_methods.none? { |p| method_match?(p, m.method) } &&
          (@lines.empty? || @lines.any? { |s| s.cover?(m) }) &&
          @exclude_lines.none? { |s| s.cover?(m) }
      end
      return kept unless @shard

      i, n = @shard
      kept.each_with_index.select { |_, idx| idx % n == i - 1 }.map(&:first)
    end

    private

    def relative(full)
      full.delete_prefix("#{@root}/")
    end

    # A pattern matches the qualified name ("Calc#add", "Calc.build", "Calc#*") or the bare method name ("add").
    def method_match?(pattern, name)
      return false if name.nil?

      bare = name.split(/[#.]/).last
      File.fnmatch?(pattern, name) || File.fnmatch?(pattern, bare)
    end

    # Files changed relative to a git ref: committed, staged and unstaged edits, plus new untracked files.
    def changed_files
      diff = git('diff', '--name-only', '--relative', @since, '--')
      untracked = git('ls-files', '--others', '--exclude-standard')
      (diff + untracked).uniq
    end

    def git(*args)
      out, err, st = Open3.capture3('git', '-C', @root, *args)
      raise Error, "git #{args.join(' ')} failed: #{err.strip}" unless st.success?

      out.split("\n").reject(&:empty?)
    end
  end
end
