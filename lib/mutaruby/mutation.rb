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
    LABEL_MAX = 80

    # Whitespace runs collapsed to one space, ends stripped.
    def self.squeeze(text)
      text.gsub(/\s+/, ' ').strip
    end

    # One-line form of a source slice, cut to LABEL_MAX characters.
    def short(str)
      s = str.gsub(/\s+/, ' ')
      s.length > LABEL_MAX ? "#{s[0, LABEL_MAX - 3]}..." : s
    end

    # Human label: "comparison: > => >="
    def label
      "#{operator}: #{short(orig)} => #{short(repl)}"
    end

    # "orig => repl", squeezed; the optional `mutation` field of an ignore entry.
    def change
      Mutation.squeeze("#{orig} => #{repl}")
    end

    def location
      "#{file}:#{lineno}"
    end

    # The replaced lines and their replacement, as a minimal unified-style diff.
    def diff(original_source)
      i = lineno - 1
      old = original_source.lines[i, orig.count("\n") + 1].map { |l| "- #{l.chomp}" }
      new = text.lines[i, repl.count("\n") + 1].map { |l| "+ #{l.chomp}" }
      (old + new).join("\n")
    end

    def to_h
      { id: id, file: file, lineno: lineno, operator: operator, method: method, line_text: line_text,
        occurrence: occurrence, orig: orig, repl: repl, change: change, label: label }
    end
  end
end
