# frozen_string_literal: true

require 'yaml'

module Mutaruby
  # The ignore file lists equivalent mutants: mutants that cannot be killed because they do not change behaviour.
  #
  # An entry names one mutation SITE, not a line number:
  #
  #   - file: lib/calc.rb                 # relative to the project root
  #     operator: comparison              # operator id
  #     line: "return 0 if n <= 0"        # the source line, whitespace-trimmed
  #     occurrence: 2                     # Nth line with exactly that text in the file (required if it is not unique)
  #     method: "Calc#clamp"              # optional: enclosing method
  #     mutation: "<= => <"               # optional: narrows the entry to one change at the site
  #     lineno: 41                        # optional hint for humans; never used for matching (it drifts)
  #     reason: "n is never negative here"   # REQUIRED
  #
  # Line numbers drift whenever code above them changes, so they are a hint only. The key is the text of the line plus
  # its occurrence among identical lines, plus the enclosing method: editing other code does not invalidate it, and
  # editing the line itself does (the entry becomes STALE and is reported, so it gets re-reviewed).
  class IgnoreFile
    class Invalid < StandardError; end

    Entry = Struct.new(:file, :operator, :line, :occurrence, :method, :mutation, :lineno, :reason, :index,
                       keyword_init: true) do
      def label
        "##{index + 1} #{file}#{lineno ? ":#{lineno}" : ''} #{operator} #{line.inspect}" \
          "#{occurrence ? " (occurrence #{occurrence})" : ''}#{method ? " in #{method}" : ''}"
      end
    end

    KEYS = %w[file operator line occurrence method mutation lineno reason].freeze

    attr_reader :entries, :path

    def self.load(path)
      new(YAML.safe_load(File.read(path), permitted_classes: [], aliases: false), path: path)
    rescue Psych::SyntaxError => e
      raise Invalid, "#{path}: not valid YAML (#{e.message})"
    end

    def initialize(data, path: '(ignore file)')
      @path = path
      data = data['ignore'] if data.is_a?(Hash) && data.key?('ignore')
      data ||= []
      raise Invalid, "#{path}: expected a list of entries" unless data.is_a?(Array)

      @entries = data.each_with_index.map { |raw, i| parse_entry(raw, i) }
    end

    # Static validation against the current sources: { rel_path => source }. Returns error strings.
    def validate(sources)
      errs = []
      @entries.each do |e|
        src = sources[e.file]
        next unless src # file not part of this run

        count = src.split("\n", -1).count { |l| l.strip == e.line }
        if count.zero?
          errs << "STALE (the line is no longer in the file; re-review or remove the entry): #{e.label}"
        elsif e.occurrence.nil? && count > 1
          errs << "AMBIGUOUS (the line occurs #{count} times; add `occurrence`): #{e.label}"
        elsif e.occurrence && e.occurrence > count
          errs << "STALE (occurrence #{e.occurrence} but the line now occurs #{count} time(s)): #{e.label}"
        end
      end
      errs
    end

    # The entry covering this mutant, or nil.
    def match(mutation)
      @entries.find do |e|
        e.file == mutation.file && e.operator == mutation.operator && e.line == mutation.line_text &&
          (e.occurrence || 1) == mutation.occurrence &&
          (e.method.nil? || e.method == mutation.method) &&
          (e.mutation.nil? || normalize(e.mutation) == mutation.change)
      end
    end

    # Entries for files in `complete_files` that matched no surviving mutant: the mutant is now killed, or the code
    # changed. Either way the entry must be removed or re-reviewed.
    def stale(matched_entries, complete_files)
      @entries.reject { |e| matched_entries.include?(e) }.select { |e| complete_files.include?(e.file) }
    end

    # YAML stubs for the given survivors (reason left empty on purpose: the file is rejected until it is filled in).
    def self.stub_for(mutations, sources)
      mutations.map do |m|
        h = { 'file' => m.file, 'operator' => m.operator, 'line' => m.line_text }
        count = sources[m.file].to_s.split("\n", -1).count { |l| l.strip == m.line_text }
        h['occurrence'] = m.occurrence if count > 1
        h['method'] = m.method if m.method
        h['mutation'] = m.change
        h['lineno'] = m.lineno
        h['reason'] = ''
        h
      end.to_yaml
    end

    private

    def normalize(s)
      s.to_s.gsub(/\s+/, ' ').strip
    end

    def parse_entry(raw, i)
      where = "#{@path}: entry ##{i + 1}"
      raise Invalid, "#{where}: expected a mapping" unless raw.is_a?(Hash)

      unknown = raw.keys.map(&:to_s) - KEYS
      raise Invalid, "#{where}: unknown key(s) #{unknown.join(', ')}" if unknown.any?

      %w[file operator line reason].each do |k|
        v = raw[k]
        raise Invalid, "#{where}: `#{k}` is required" if v.nil? || v.to_s.strip.empty?
      end
      %w[occurrence lineno].each do |k|
        v = raw[k]
        raise Invalid, "#{where}: `#{k}` must be a positive integer" unless v.nil? || (v.is_a?(Integer) && v.positive?)
      end
      unless Generator::OPERATORS.key?(raw['operator'].to_s)
        raise Invalid, "#{where}: unknown operator #{raw['operator'].inspect}"
      end

      Entry.new(file: raw['file'].to_s.sub(%r{\A\./}, ''), operator: raw['operator'].to_s, line: raw['line'].to_s.strip,
                occurrence: raw['occurrence'], method: raw['method']&.to_s, mutation: raw['mutation']&.to_s,
                lineno: raw['lineno'], reason: raw['reason'].to_s.strip, index: i)
    end
  end
end
