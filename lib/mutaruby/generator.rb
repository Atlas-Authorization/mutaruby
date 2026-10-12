# frozen_string_literal: true

require_relative 'parsing'
require_relative 'mutation'
require_relative 'splicer'
require_relative 'render'

module Mutaruby
  # Walks a file's AST (the `parser` gem) and produces every mutant of it. Each mutant is ONE splice of the original
  # source at the character offsets of an AST node (or of one of its tokens), so comments, formatting and the rest of
  # the file are untouched. Mutants that no longer parse, and mutants whose text equals an earlier one, are dropped.
  class Generator
    # Operator id => one-line description. The README documents each with an example.
    OPERATORS = {
      'arithmetic' => 'swap + - * / % ** (a + b -> a - b, a * b -> a / b, a % b -> a * b, a ** b -> a * b)',
      'comparison' => 'boundary / equality swaps (== <-> !=, < -> <=, <= -> <, > -> >=, >= -> >, <=> -> ==, === -> !=, =~ <-> !~)',
      'bitwise' => 'swap & | ^ << >> (a & b -> a | b, a << b -> a >> b)',
      'logical-swap' => '&& <-> ||, and <-> or',
      'logical-drop-left' => 'a && b -> b, a || b -> b',
      'logical-drop-right' => 'a && b -> a, a || b -> a',
      'negation-removal' => '!x -> x, not x -> x',
      'unary-minus-removal' => '-x -> x',
      'condition-negate' => 'if c / unless c / c ? a : b: c -> !(c)',
      'condition-true' => 'if c: c -> true',
      'condition-false' => 'if c: c -> false',
      'loop-condition-negate' => 'while c / until c: c -> !(c)',
      'loop-condition-false' => 'while c: c -> false',
      'literal-int' => 'n -> n + 1, n - 1, 0, 1 (each distinct value once)',
      'literal-float' => 'x -> 0.0, x + 1.0',
      'literal-string' => '"abc" -> "", "" -> "mutaruby" (also single-quoted and %q/%Q strings)',
      'literal-symbol' => ':sym -> :__mutaruby__',
      'literal-boolean' => 'true <-> false',
      'literal-nil' => 'nil -> true',
      'literal-array' => '[a, b] -> []',
      'literal-hash' => '{ k => v } -> {}',
      'range-swap' => 'a..b <-> a...b',
      'return-nil' => 'return x -> return nil',
      'method-body-nil' => 'def m; body; end -> def m; nil; end',
      'method-body-bool' => 'def m?; body; end -> true / false (predicate methods only)',
      'statement-delete' => 'one statement of a multi-statement body -> nil',
      'argument-removal' => 'f(a, b) -> f(b), f(a) (one argument removed at a time)',
      'call-to-receiver' => 'recv.m(args) -> recv',
      'call-to-argument' => 'recv.m(a, ...) -> a',
      'predicate-true' => 'x.m? -> true',
      'predicate-false' => 'x.m? -> false',
      'safe-navigation' => 'a&.m -> a.m',
      'raise-removal' => 'raise X -> nil (also fail)',
      'op-assign' => 'swap compound assignment (+= <-> -=, *= <-> /=, |= <-> &=, <<= <-> >>=)',
      'or-assign' => 'a ||= b -> a = b',
      'and-assign' => 'a &&= b -> a = b',
      'block-removal' => 'list.map { |x| f(x) } -> list.map (the call without its block)',
      'method-swap' => 'swap a method for its counterpart (first <-> last, min <-> max, select <-> reject, ...)',
      'element-removal' => '[a, b] -> [b], [a]; { k: 1, j: 2 } -> { j: 2 }, { k: 1 } (one element removed at a time)',
      'regexp-never-match' => '/pattern/ -> /(?!)/ (a regexp that matches nothing)',
      'yield-removal' => 'yield x -> nil',
      'super-removal' => 'super / super(x) -> nil',
      'when-removal' => 'one `when` branch of a case removed',
      'rescue-removal' => 'one `rescue` clause removed'
    }.freeze

    # method-swap pairs: each method and the one it is replaced with.
    METHOD_SWAPS = {
      first: :last, last: :first, min: :max, max: :min, min_by: :max_by, max_by: :min_by, any?: :all?, all?: :any?,
      select: :reject, reject: :select, filter: :reject, upcase: :downcase, downcase: :upcase, floor: :ceil,
      ceil: :floor, succ: :pred, pred: :succ, keys: :values, values: :keys, start_with?: :end_with?,
      end_with?: :start_with?, take: :drop, drop: :take, take_while: :drop_while, drop_while: :take_while,
      push: :unshift, unshift: :push, pop: :shift, shift: :pop
    }.freeze

    SWAPS = {
      'arithmetic' => { :+ => :-, :- => :+, :* => :/, :/ => :*, :% => :*, :** => :* },
      'comparison' => { :== => :!=, :!= => :==, :< => :<=, :<= => :<, :> => :>=, :>= => :>, :<=> => :==,
                        :=== => :!=, :=~ => :!~, :!~ => :=~ },
      'bitwise' => { :& => :|, :| => :&, :^ => :&, :<< => :>>, :>> => :<< }
    }.freeze
    OP_ASSIGN = { :+ => :-, :- => :+, :* => :/, :/ => :*, :| => :&, :& => :|, :<< => :>>, :>> => :<< }.freeze

    # Calls that are declarations, not computations: their arguments are never removed and their string arguments are
    # never emptied (a mutant of `require 'json'` that requires "" is noise, not a test gap).
    DECLARATIONS = %i[require require_relative load autoload attr_reader attr_writer attr_accessor include extend prepend
                      private public protected module_function private_constant public_constant
                      private_class_method public_class_method define_method alias_method raise fail].freeze
    # Bare visibility calls (`private` on its own line) are never deleted: that only changes which methods are public.
    VISIBILITY_CALLS = %i[private public protected module_function].map { |v| Parser::AST::Node.new(:send, [nil, v]) }.freeze
    # Definitions are not deleted as statements: deleting a whole class or method is caught by any test that touches
    # it, and the interesting mutants are inside (method-body-nil and the operators on the body).
    STRUCTURAL = %i[module class sclass def defs].freeze
    PREDICATE_SKIP = %i[block_given? frozen? respond_to? respond_to_missing? nil?].freeze
    DISABLE_MARK = 'mutaruby:disable'
    MAX_ARGS = 6 # argument-removal skips calls with more arguments than this

    attr_reader :errors

    # path: file path for messages; rel: path relative to the project root (stored on the mutants).
    # operators: nil (all) or a list of operator ids.
    # renderer: :text (default) builds replacements from the source text; :unparser renders the operators that rebuild
    # a node (element-removal) with the `unparser` gem instead, which must be installed.
    def initialize(source, path:, rel: path, operators: nil, renderer: :text)
      @src = source
      @renderer = renderer
      @path = path
      @rel = rel
      @operators = operators
      @valid_encoding = source.valid_encoding?
      @lines = @valid_encoding ? source.lines.map(&:strip) : []
      @occurrence = occurrence_index(@lines)
      @errors = []
    end

    def mutations
      @mutations ||= build
    end

    private

    def build
      unless @valid_encoding
        @errors << "#{@path}: cannot parse (not valid #{@src.encoding}); skipped"
        return []
      end
      ast = Parsing.parse(@path, normalize_newlines)
      @out = []
      @seen = {}
      @scope = []   # namespace names ("Foo", "Bar")
      @meth = []    # enclosing method names, qualified; @singleton: inside `class << self`
      walk(ast, nil)
      @out.each_with_index { |m, i| m.id = i }
    rescue Parser::SyntaxError => e
      @errors << "#{@path}: cannot parse (#{e}); skipped"
      []
    end

    # `parser` reads every "\r\n" as "\n", so its offsets count one character per CRLF line break. The source is
    # parsed in that form; @crlf records where (in parser offsets) a "\n" stands for "\r\n" in the file, so every
    # splice is made at the file's own character offsets and the file keeps its line endings.
    def normalize_newlines
      @crlf = {}
      norm = @src.gsub("\r\n") do
        @crlf[$~.begin(0) - @crlf.size] = true
        "\n"
      end
      @newline = @crlf.empty? ? "\n" : "\r\n"
      norm
    end

    def original_offset(pos)
      pos + @crlf.count { |q, _| q < pos }
    end

    # A slice of the parsed source as it reads in the file.
    def with_crlf(slice, start)
      slice.each_char.with_index.map { |c, i| @crlf[start + i] ? "\r\n" : c }.join
    end

    # lineno => 1-based index of that line among the identical (stripped) lines of the file.
    def occurrence_index(lines)
      seen = Hash.new(0)
      lines.each_with_index.to_h { |l, i| [i + 1, seen[l] += 1] }
    end

    def enabled?(op)
      @operators.nil? || @operators.include?(op)
    end

    # Splices `repl` over `range` (a Parser::Source::Range) and records the mutant if it is new and still parses.
    def add(range, repl, op)
      return unless enabled?(op)

      orig = range.source
      return if orig == repl

      lineno = range.line
      line = @lines[lineno - 1]
      return if line.include?(DISABLE_MARK)

      b = range.begin_pos
      text = Splicer.splice(@src, original_offset(b), original_offset(range.end_pos), with_crlf(orig, b),
                            repl.gsub("\n", @newline))
      return if @seen[text]

      @seen[text] = true
      return unless Parsing.valid?(@path, text)

      @out << Mutation.new(file: @rel, operator: op, orig: orig, repl: repl, lineno: lineno, line_text: line,
                           occurrence: @occurrence[lineno], method: @meth.last, text: text)
    end

    def declaration?(node)
      node&.type == :send && DECLARATIONS.include?(node.children[1])
    end

    def src_of(node)
      node.loc.expression.source
    end

    def walk(node, parent)
      return unless node.is_a?(Parser::AST::Node)

      case node.type
      when :module, :class
        @scope.push(src_of(node.children[0]))
        walk_children(node)
        @scope.pop
      when :sclass
        outer = @singleton
        @singleton = true
        walk_children(node)
        @singleton = outer
      when :def, :defs
        @meth.push(qualified(node))
        visit(node, parent)
        walk_children(node)
        @meth.pop
      else
        visit(node, parent)
        walk_children(node)
      end
    end

    def walk_children(node)
      node.children.each { |c| walk(c, node) }
    end

    def qualified(node)
      ns = @scope.join('::')
      if node.type == :defs
        "#{ns.empty? ? src_of(node.children[0]) : ns}.#{node.children[1]}"
      elsif @singleton
        "#{ns}.#{node.children[0]}"
      else
        ns.empty? ? node.children[0].to_s : "#{ns}##{node.children[0]}"
      end
    end

    def visit(n, parent)
      case n.type
      when :send, :csend then visit_send(n, parent)
      when :and, :or then visit_logical(n)
      when :if then visit_if(n)
      when :while, :until, :while_post, :until_post then visit_loop(n)
      when :int then visit_int(n)
      when :float then visit_float(n)
      when :str then visit_str(n, parent)
      when :sym
        add(n.loc.expression, ':__mutaruby__', 'literal-symbol') if n.loc.expression.source.match?(/\A:[A-Za-z_]\w*[?!=]?\z/) &&
                                                                    !declaration?(parent)
      when :true then add(n.loc.expression, 'false', 'literal-boolean')
      when :false then add(n.loc.expression, 'true', 'literal-boolean')
      when :nil then add(n.loc.expression, 'true', 'literal-nil')
      when :array then visit_collection(n, '[', '[]', 'literal-array')
      when :hash then visit_collection(n, '{', '{}', 'literal-hash')
      when :irange, :erange
        # an endless range (a..) means the same with either operator
        add(n.loc.operator, n.type == :irange ? '...' : '..', 'range-swap') unless n.children[1].nil?
      when :return
        add(n.loc.expression, 'return nil', 'return-nil') if n.children.any?
      when :op_asgn
        sw = OP_ASSIGN[n.children[1]]
        add(n.loc.operator, "#{sw}=", 'op-assign') if sw
      when :or_asgn then add(n.loc.operator, '=', 'or-assign')
      when :and_asgn then add(n.loc.operator, '=', 'and-assign')
      when :begin, :kwbegin then visit_body(n)
      when :def, :defs then visit_def(n)
      when :block, :numblock then add(n.loc.expression, src_of(n.children.first), 'block-removal')
      when :regexp then add(n.loc.expression, '/(?!)/', 'regexp-never-match')
      when :yield then add(n.loc.expression, 'nil', 'yield-removal')
      when :super, :zsuper then add(n.loc.expression, 'nil', 'super-removal')
      when :case then remove_clauses(n.children[1...-1], 'when-removal')
      when :rescue then remove_clauses(n.children[1...-1], 'rescue-removal')
      end
    end

    # A bracketed array / braced hash: emptied, and each element removed in turn.
    def visit_collection(n, open, empty, op)
      return unless n.loc.begin&.source == open

      add(n.loc.expression, empty, op) if n.children.any?
      remove_elements(n) if n.children.size.between?(2, MAX_ARGS)
    end

    # Each clause (a `when`, a `rescue`) deleted in turn; the validity check drops what would not parse.
    def remove_clauses(clauses, op)
      clauses.each { |c| add(c.loc.expression, '', op) }
    end

    # [a, b, c] -> [b, c], [a, c], [a, b] (and the same for the pairs of a braced hash).
    def remove_elements(n)
      kids = n.children
      kids.each_index do |i|
        rest = kids.reject.with_index { |_, j| j == i }
        if @renderer == :unparser
          add(n.loc.expression, Render.unparse(src_of(n), i), 'element-removal')
        else
          add(kids.first.loc.expression.join(kids.last.loc.expression), rest.map { |k| src_of(k) }.join(', '),
              'element-removal')
        end
      end
    end

    def visit_send(n, parent)
      recv, meth, *args = *n
      SWAPS.each do |op, table|
        add(n.loc.selector, table[meth].to_s, op) if table.key?(meth) && args.size == 1
      end
      add(n.loc.selector, METHOD_SWAPS[meth].to_s, 'method-swap') if recv && METHOD_SWAPS.key?(meth)
      add(n.loc.expression, src_of(recv), 'negation-removal') if meth == :!
      add(n.loc.expression, src_of(recv), 'unary-minus-removal') if meth == :-@
      add(n.loc.dot, '.', 'safe-navigation') if n.type == :csend
      add(n.loc.expression, 'nil', 'raise-removal') if recv.nil? && %i[raise fail].include?(meth)
      if meth.end_with?('?') && !PREDICATE_SKIP.include?(meth)
        add(n.loc.expression, 'true', 'predicate-true')
        add(n.loc.expression, 'false', 'predicate-false')
      end
      plain = meth.match?(/\A[a-z_]\w*[?!]?\z/) # a named method, not an operator or a writer
      block_call = parent&.type == :block && parent.children[0].equal?(n)
      if recv && plain && !block_call
        add(n.loc.expression, src_of(recv), 'call-to-receiver')
        add(n.loc.expression, src_of(args.first), 'call-to-argument') if args.any?
      end
      remove_arguments(args) if plain && !DECLARATIONS.include?(meth) && args.size.between?(1, MAX_ARGS)
    end

    def remove_arguments(args)
      range = args.first.loc.expression.join(args.last.loc.expression)
      args.each_index do |i|
        rest = args.reject.with_index { |_, j| j == i }
        add(range, rest.map { |a| src_of(a) }.join(', '), 'argument-removal')
      end
    end

    def visit_logical(n)
      l, r = *n
      kw = n.loc.operator.source
      repl = { '&&' => '||', '||' => '&&', 'and' => 'or', 'or' => 'and' }.fetch(kw)
      add(n.loc.operator, repl, 'logical-swap')
      add(n.loc.expression, src_of(l), 'logical-drop-right')
      add(n.loc.expression, src_of(r), 'logical-drop-left')
    end

    def visit_if(n)
      cond = n.children.first
      add(cond.loc.expression, "!(#{src_of(cond)})", 'condition-negate')
      add(cond.loc.expression, 'true', 'condition-true')
      add(cond.loc.expression, 'false', 'condition-false')
    end

    def visit_loop(n)
      cond = n.children.first
      add(cond.loc.expression, "!(#{src_of(cond)})", 'loop-condition-negate')
      add(cond.loc.expression, 'false', 'loop-condition-false') if %i[while while_post].include?(n.type)
    end

    def visit_int(n)
      v = n.children.first
      [v + 1, v - 1, 0, 1].each { |x| add(n.loc.expression, x.to_s, 'literal-int') }
    end

    def visit_float(n)
      v = n.children.first
      add(n.loc.expression, '0.0', 'literal-float') unless v.zero?
      add(n.loc.expression, (v + 1.0).to_s, 'literal-float') if v.finite?
    end

    # Strings with both delimiters in the source: '...', "...", %q(...), %Q[...]. Not heredocs, not the parts of an
    # interpolated string, not %w elements, not ?c character literals.
    def visit_str(n, parent)
      return if declaration?(parent)

      open = n.loc.begin if n.loc.respond_to?(:begin)
      close = n.loc.end if open
      return unless close

      fill = n.children.first.empty? ? 'mutaruby' : ''
      add(n.loc.expression, "#{open.source}#{fill}#{close.source}", 'literal-string')
    end

    def visit_body(n)
      return unless n.children.size > 1

      n.children.each do |k|
        next if STRUCTURAL.include?(k.type) || VISIBILITY_CALLS.include?(k)

        add(k.loc.expression, 'nil', 'statement-delete')
      end
    end

    def visit_def(n)
      body = n.children.last
      return unless body

      add(body.loc.expression, 'nil', 'method-body-nil')
      return unless n.children[n.type == :def ? 0 : 1].end_with?('?')

      add(body.loc.expression, 'true', 'method-body-bool')
      add(body.loc.expression, 'false', 'method-body-bool')
    end
  end
end
