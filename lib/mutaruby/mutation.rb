# frozen_string_literal: true

module Mutaruby
  # One mutant: a single source edit of one file.
  #
  #   file       path of the mutated file, relative to the project root
  #   operator   operator id (see OPERATORS / README)
  #   orig, repl the replaced source slice and its replacement
  #   lineno     1-based line where the replaced slice starts
  #   line_text  that line, stripped (part of the site key)
  #   occurrence 1-based index of line_text among the identical (stripped) lines of the file (part of the site key)
  #   method     enclosing method, qualified: "Foo::Bar#baz" (instance), "Foo::Bar.baz" (singleton), nil at top level
  #   text       the complete mutated file
  Mutation = Struct.new(:id, :file, :operator, :orig, :repl, :lineno, :line_text, :occurrence, :method, :text,
                        keyword_init: true) do
    def short(str, max = 80)
      s = str.gsub(/\s+/, ' ')
      s.length > max ? "#{s[0, max - 3]}..." : s
    end

    # Human label: "comparison: > => >="
    def label
      "#{operator}: #{short(orig)} => #{short(repl)}"
    end

    # Normalised "orig => repl" (whitespace collapsed); the optional `mutation` field of an ignore entry.
    def change
      "#{orig.gsub(/\s+/, ' ').strip} => #{repl.gsub(/\s+/, ' ').strip}"
    end

    def location
      "#{file}:#{lineno}"
    end

    # The mutated region with one line of context, as a minimal unified-style diff.
    def diff(original_source)
      lines = original_source.lines
      mlines = text.lines
      i = lineno - 1
      orig_n = orig.count("\n") + 1
      repl_n = repl.count("\n") + 1
      out = []
      (lines[i, orig_n] || []).each { |l| out << "- #{l.chomp}" }
      (mlines[i, repl_n] || []).each { |l| out << "+ #{l.chomp}" }
      out.join("\n")
    end

    def to_h
      { id: id, file: file, lineno: lineno, operator: operator, method: method, line_text: line_text,
        occurrence: occurrence, orig: orig, repl: repl, change: change, label: label }
    end
  end
end
