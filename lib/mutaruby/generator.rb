# frozen_string_literal: true

require_relative 'parsing'
require_relative 'mutation'
require_relative 'splicer'

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
      'literal-string' => '"abc" -> "", "" -> "mutaruby"',
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
      'and-assign' => 'a &&= b -> a = b'
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
    VISIBILITY = %i[private public protected module_function].freeze
    # Definitions are not deleted as statements: deleting a whole class or method is caught by any test that touches
    # it, and the interesting mutants are inside (method-body-nil and the operators on the body).
    STRUCTURAL = %i[module class sclass def defs].freeze
    PREDICATE_SKIP = %i[block_given? frozen? respond_to? respond_to_missing? nil?].freeze
    DISABLE_MARK = 'mutaruby:disable'

    attr_reader :errors

    # path: file path for messages; rel: path relative to the project root (stored on the mutants).
    def initialize(source, path:, rel: path, operators: nil)
      @src = source
      @path = path
      @rel = rel
      @operators = operators # nil = all, else a Set of ids
      @valid_encoding = source.valid_encoding?
      @lines = @valid_encoding ? source.split("\n", -1) : []
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
      ast = Parsing.parse(@path, @src)
      @out = []
      @seen = {}
      @scope = []  # namespace names ("Foo", "Bar")
      @meth = []   # enclosing method names, qualified
      @singleton = 0
      walk(ast, nil) if ast
      @out.each_with_index { |m, i| m.id = i }
      @out
    rescue Parser::SyntaxError, EncodingError, ArgumentError => e
      @errors << "#{@path}: cannot parse (#{e.message}); skipped"
      []
    end

    def occurrence_index(lines)
      seen = Hash.new(0)
      lines.each_with_index.to_h { |l, i| [i + 1, seen[l.strip] += 1] }
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
      line = @lines[lineno - 1].to_s
      return if line.include?(DISABLE_MARK)

      text = Splicer.splice(@src, range.begin_pos, range.end_pos, orig, repl)
      return if @seen[text]

      @seen[text] = true
      return unless Parsing.valid?(@path, text)

      @out << Mutation.new(file: @rel, operator: op, orig: orig, repl: repl, lineno: lineno, line_text: line.strip,
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
        visit(node, parent)
        @scope.push(src_of(node.children[0]))
        node.children.each { |c| walk(c, node) }
        @scope.pop
      when :sclass
        visit(node, parent)
        @singleton += 1
        node.children.each { |c| walk(c, node) }
        @singleton -= 1
      when :def, :defs
        @meth.push(qualified(node))
        visit(node, parent)
        node.children.each { |c| walk(c, node) }
        @meth.pop
      else
        visit(node, parent)
        node.children.each { |c| walk(c, node) }
      end
    end

    def qualified(node)
      ns = @scope.join('::')
      if node.type == :defs
        "#{ns.empty? ? src_of(node.children[0]) : ns}.#{node.children[1]}"
      elsif @singleton.positive?
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
      when :array
        add(n.loc.expression, '[]', 'literal-array') if n.children.any? && n.loc.begin&.source == '['
      when :hash
        add(n.loc.expression, '{}', 'literal-hash') if n.children.any? && n.loc.begin&.source == '{'
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
      end
    end

    def visit_send(n, parent)
      recv, meth, *args = *n
      sel = n.loc.selector
      SWAPS.each do |op, table|
        add(sel, table[meth].to_s, op) if table.key?(meth) && recv && args.size == 1 && sel
      end
      if meth == :! && recv
        add(n.loc.expression, src_of(recv), 'negation-removal')
      elsif meth == :-@ && recv
        add(n.loc.expression, src_of(recv), 'unary-minus-removal')
      end
      add(n.loc.dot, '.', 'safe-navigation') if n.type == :csend && n.loc.dot
      if recv.nil? && %i[raise fail].include?(meth)
        add(n.loc.expression, 'nil', 'raise-removal')
        return
      end
      name = meth.to_s
      if name.end_with?('?') && !PREDICATE_SKIP.include?(meth)
        add(n.loc.expression, 'true', 'predicate-true')
        add(n.loc.expression, 'false', 'predicate-false')
      end
      plain = name.match?(/\A[a-z_]\w*[?!]?\z/) # a named method, not an operator or a writer
      block_call = parent&.type == :block && parent.children[0].equal?(n)
      if recv && plain && sel && !block_call
        add(n.loc.expression, src_of(recv), 'call-to-receiver')
        first = args.first
        add(n.loc.expression, src_of(first), 'call-to-argument') if first && !%i[block_pass splat kwsplat hash].include?(first.type)
      end
      remove_arguments(n, args) if plain && !DECLARATIONS.include?(meth) && args.any? && parent&.type != :masgn
    end

    def remove_arguments(n, args)
      return if args.size > 6

      first = args.first.loc.expression
      last = args.last.loc.expression
      range = first.join(last)
      args.each_index do |i|
        rest = args.each_with_index.reject { |_, j| j == i }.map { |a, _| src_of(a) }
        add(range, rest.join(', '), 'argument-removal')
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
      cond = n.children[0]
      return unless cond.is_a?(Parser::AST::Node)

      add(cond.loc.expression, "!(#{src_of(cond)})", 'condition-negate')
      add(cond.loc.expression, 'true', 'condition-true')
      add(cond.loc.expression, 'false', 'condition-false')
    end

    def visit_loop(n)
      cond = n.children[0]
      add(cond.loc.expression, "!(#{src_of(cond)})", 'loop-condition-negate')
      add(cond.loc.expression, 'false', 'loop-condition-false') if %i[while while_post].include?(n.type)
    end

    def visit_int(n)
      v = n.children[0]
      [v + 1, v - 1, 0, 1].uniq.reject { |x| x == v }.each { |x| add(n.loc.expression, x.to_s, 'literal-int') }
    end

    def visit_float(n)
      v = n.children[0]
      add(n.loc.expression, '0.0', 'literal-float') unless v.zero?
      add(n.loc.expression, (v + 1.0).to_s, 'literal-float') if v.finite?
    end

    def visit_str(n, parent)
      return if parent && %i[dstr xstr dsym regexp].include?(parent.type)
      return if declaration?(parent)

      q = n.loc.respond_to?(:begin) && n.loc.begin ? n.loc.begin.source : nil
      return unless ['"', "'"].include?(q)

      if n.children[0].empty?
        add(n.loc.expression, "#{q}mutaruby#{q}", 'literal-string')
      else
        add(n.loc.expression, "#{q}#{q}", 'literal-string')
      end
    end

    def visit_body(n)
      kids = n.children
      return unless kids.size > 1

      kids.each do |k|
        next unless k.is_a?(Parser::AST::Node)
        next if STRUCTURAL.include?(k.type)
        next if k.type == :send && k.children[0].nil? && VISIBILITY.include?(k.children[1]) && k.children.size == 2

        add(k.loc.expression, 'nil', 'statement-delete')
      end
    end

    def visit_def(n)
      body = n.children.last
      return unless body.is_a?(Parser::AST::Node)

      add(body.loc.expression, 'nil', 'method-body-nil')
      name = n.type == :def ? n.children[0] : n.children[1]
      return unless name.to_s.end_with?('?')

      add(body.loc.expression, 'true', 'method-body-bool')
      add(body.loc.expression, 'false', 'method-body-bool')
    end
  end
end
