# frozen_string_literal: true

require_relative '../test_helper'

class GeneratorTest < Minitest::Test
  include TestHelpers

  def test_every_operator_is_documented
    Mutaruby::Generator::OPERATORS.each do |id, desc|
      assert_match(/\A[a-z]+(-[a-z]+)*\z/, id)
      refute_empty desc.strip, id
    end
  end

  def test_arithmetic
    assert_equal ['+ => -', '- => +', '* => /', '/ => *', '% => *', '** => *'],
                 changes("a + b\na - b\na * b\na / b\na % b\na ** b\n", 'arithmetic')
  end

  def test_comparison
    src = "a == b\na != b\na < b\na <= b\na > b\na >= b\na <=> b\na === b\na =~ b\na !~ b\n"
    assert_equal ['== => !=', '!= => ==', '< => <=', '<= => <', '> => >=', '>= => >', '<=> => ==', '=== => !=',
                  '=~ => !~', '!~ => =~'], changes(src, 'comparison')
  end

  def test_bitwise
    assert_equal ['& => |', '| => &', '^ => &', '<< => >>', '>> => <<'],
                 changes("a & b\na | b\na ^ b\na << b\na >> b\n", 'bitwise')
  end

  def test_operator_swaps_need_a_receiver_and_one_argument
    assert_empty changes("x.+(1, 2)\n", 'arithmetic')
    assert_equal ['+ => -'], changes("x.+(1)\n", 'arithmetic')
  end

  def test_logical
    assert_equal ['&& => ||', '|| => &&', 'and => or', 'or => and'],
                 changes("a && b\na || b\na and b\na or b\n", 'logical-swap')
    assert_equal ['a && b => a'], changes("a && b\n", 'logical-drop-right')
    assert_equal ['a && b => b'], changes("a && b\n", 'logical-drop-left')
  end

  def test_negation_and_unary_minus
    assert_equal ['!a => a', 'not a => a'], changes("!a\nnot a\n", 'negation-removal')
    assert_equal ['-a => a'], changes("-a\n", 'unary-minus-removal')
  end

  def test_conditions
    src = "x if c\ny unless d\nc ? 1 : 2\nif e then 1 elsif f then 2 end\n"
    assert_equal ['c => !(c)', 'd => !(d)', 'c => !(c)', 'e => !(e)', 'f => !(f)'], changes(src, 'condition-negate')
    assert_equal ['c => true', 'd => true', 'c => true', 'e => true', 'f => true'], changes(src, 'condition-true')
    assert_equal 5, changes(src, 'condition-false').size
  end

  def test_loops
    src = "x while a\ny until b\n"
    assert_equal ['a => !(a)', 'b => !(b)'], changes(src, 'loop-condition-negate')
    assert_equal ['a => false'], changes(src, 'loop-condition-false')
  end

  def test_integer_literals
    assert_equal ['5 => 6', '5 => 4', '5 => 0', '5 => 1'], changes("x = 5\n", 'literal-int')
    assert_equal ['0 => 1', '0 => -1'], changes("x = 0\n", 'literal-int')
    assert_equal ['1 => 2', '1 => 0'], changes("x = 1\n", 'literal-int')
    assert_equal ['-1 => 0', '-1 => -2', '-1 => 1'], changes("x = -1\n", 'literal-int')
  end

  def test_float_literals
    assert_equal ['2.5 => 0.0', '2.5 => 3.5'], changes("x = 2.5\n", 'literal-float')
    assert_equal ['0.0 => 1.0'], changes("x = 0.0\n", 'literal-float')
  end

  def test_string_literals
    assert_equal ["'a' => ''", '"" => "mutaruby"'], changes("x = 'a'\ny = \"\"\n", 'literal-string')
  end

  def test_strings_that_are_not_mutated
    src = "require 'json'\nx = \"a\#{b}c\"\ny = %w[p q]\nz = <<~T\n  hi\nT\n"
    assert_empty changes(src, 'literal-string')
  end

  def test_symbols_booleans_nil_collections_ranges
    assert_equal [':a => :__mutaruby__'], changes("x = :a\n", 'literal-symbol')
    assert_empty changes("x = { a: 1 }\n", 'literal-symbol')
    assert_empty changes("attr_reader :a\nprivate :b\n", 'literal-symbol')
    assert_equal ['true => false', 'false => true'], changes("x = true\ny = false\n", 'literal-boolean')
    assert_equal ['nil => true'], changes("x = nil\n", 'literal-nil')
    assert_equal ['[1] => []'], changes("x = [1]\n", 'literal-array')
    assert_empty changes("x = []\n", 'literal-array')
    assert_equal ['{ a: 1 } => {}'], changes("x = { a: 1 }\n", 'literal-hash')
    assert_equal ['.. => ...', '... => ..', '.. => ...'], changes("a..b\na...b\n(..b)\n(a..)\n(a...)\n", 'range-swap')
  end

  def test_return_and_method_bodies
    assert_equal ['return x => return nil'], changes("def f\n  return x\nend\n", 'return-nil')
    assert_empty changes("def f\n  return\nend\n", 'return-nil')
    assert_equal ['x => nil'], changes("def f\n  x\nend\n", 'method-body-nil')
    assert_equal ['a b => nil'], changes("def f\n  a\n  b\nend\n", 'method-body-nil')
    assert_equal ['x => true', 'x => false'], changes("def ok?\n  x\nend\n", 'method-body-bool')
    assert_empty changes("def ok\n  x\nend\n", 'method-body-bool')
    assert_equal ['1 => nil'], changes("def self.f = 1\n", 'method-body-nil')
  end

  def test_statement_deletion
    src = "def f\n  private\n  a\n  b\nend\n"
    assert_equal ['a => nil', 'b => nil'], changes(src, 'statement-delete')
    src = "class A\n  private\n  def x; end\n  Z = 1\nend\n"
    assert_equal ['Z = 1 => nil'], changes(src, 'statement-delete')
    assert_empty changes("a\n".dup, 'statement-delete')
  end

  def test_argument_removal
    assert_equal ['a, b => b', 'a, b => a'], changes("f(a, b)\n", 'argument-removal')
    assert_equal ['a =>'], changes("o.f(a)\n", 'argument-removal')
    assert_empty changes("require 'x'\nattr_reader :a\nraise E, 'm'\n", 'argument-removal')
  end

  def test_calls
    assert_equal ['o.f(a) => o'], changes("o.f(a)\n", 'call-to-receiver')
    assert_equal ['o.f(a) => a'], changes("o.f(a)\n", 'call-to-argument')
    assert_equal ['o.f => o'], changes("o.f\n", 'call-to-receiver')
    assert_empty changes("o.f(&b)\n", 'call-to-argument')
    assert_empty changes("o.each { |x| x }\n", 'call-to-receiver')
    assert_empty changes("o.f = 1\n", 'call-to-receiver')
  end

  def test_predicates
    assert_equal ['o.ok? => true', 'ok? => true'], changes("o.ok?\nok?\n", 'predicate-true')
    assert_equal ['o.ok? => false'], changes("o.ok?\nblock_given?\n", 'predicate-false')
  end

  def test_safe_navigation_raise_and_assignments
    assert_equal ['&. => .'], changes("a&.b\n", 'safe-navigation')
    assert_equal ['raise E => nil', "fail 'x' => nil"], changes("raise E\nfail 'x'\n", 'raise-removal')
    assert_empty changes("o.raise E\n", 'raise-removal')
    assert_equal ['+= => -=', '-= => +=', '*= => /=', '|= => &='], changes("a += 1\na -= 1\na *= 2\na |= b\n", 'op-assign')
    assert_equal ['||= => ='], changes("a ||= b\n", 'or-assign')
    assert_equal ['&&= => ='], changes("a &&= b\n", 'and-assign')
  end

  def test_operator_filter
    ms = muts("a + b == c\n", operators: ['comparison'])
    assert_equal ['comparison'], ms.map(&:operator).uniq
  end

  def test_drops_duplicates_and_unparsable_mutants
    ms = muts("x = 1\n")
    assert_equal ms.map(&:text).uniq.size, ms.size
    ms.each { |m| assert Mutaruby::Parsing.valid?('t.rb', m.text), m.label }
    assert_empty triples("def f(a = 1, *); end\n").select { |op, _, _| op == 'argument-removal' }
  end

  def test_disable_comment
    assert_empty muts("x = a + b # mutaruby:disable\n")
    refute_empty muts("x = a + b\n")
  end

  def test_qualified_method_names_and_site_fields
    src = <<~RUBY
      module A
        class B
          def i; 1; end
          def self.s; 2; end
          class << self
            def t; 3; end
          end
        end
        def m; 4; end
      end
      def top; 5; end
      def x.y; 6; end
      Z = 7
    RUBY
    names = muts(src, operators: ['literal-int']).map(&:method).uniq
    assert_equal ['A::B#i', 'A::B.s', 'A::B.t', 'A#m', 'top', 'x.y', nil], names
  end

  def test_occurrence_and_line_text
    src = "def a\n  return 1\nend\ndef b\n  return 1\nend\n"
    ms = muts(src, operators: ['return-nil'])
    assert_equal [[2, 'return 1', 1, 'a'], [5, 'return 1', 2, 'b']], ms.map { |m| [m.lineno, m.line_text, m.occurrence, m.method] }
    assert_equal [0, 1], ms.map(&:id)
    assert_equal 'snippet.rb', ms.first.file
  end

  def test_unparsable_file_is_reported_not_raised
    g = Mutaruby::Generator.new("def (\n", path: 'bad.rb')
    assert_empty g.mutations
    assert_match(/bad\.rb: cannot parse/, g.errors.first)
    g = Mutaruby::Generator.new("x = '\xff'\n".dup.force_encoding('UTF-8'), path: 'enc.rb')
    assert_empty g.mutations
    assert_match(/enc\.rb: cannot parse/, g.errors.first)
  end

  def test_mutation_label_diff_and_hash
    m = muts("x = a +   b\n", operators: ['arithmetic']).first
    assert_equal 'arithmetic: + => -', m.label
    assert_equal "- x = a +   b\n+ x = a -   b", m.diff("x = a +   b\n")
    assert_equal 'snippet.rb:1', m.location
    h = m.to_h
    assert_equal '+ => -', h[:change]
    assert_equal 1, h[:occurrence]
    assert_equal 'x = a +   b', h[:line_text]
    long = muts("x = #{'a' * 100} ? 1 : 2\n", operators: ['condition-true']).first
    assert_equal 80, long.short(long.orig).size
    assert long.short(long.orig).end_with?('...')
  end

  CORPUS = <<~RUBY
    # é
    module M
      def self.f(a, b = 1, *r, k: 2, **o, &blk)
        return nil if a.nil?
        x = a&.size || 0
        y = [a, b].map { |v| v * 2 }
        z = { a: 1, "b" => -b }
        raise ArgumentError, 'bad' unless x >= 0 && !y.empty?
        begin
          w = x.fdiv(3.5)
        rescue ZeroDivisionError
          w = 0.0
        end
        (0...x).each { |i| w += i ** 2 }
        w
      end
    end
  RUBY

  # Properties of every mutant: one edit, never the original text, never a duplicate, always parsable.
  def test_mutant_properties
    ms = muts(CORPUS)
    assert_operator ms.size, :>, 50
    assert_equal ms.size, ms.map(&:text).uniq.size
    ms.each do |m|
      refute_equal CORPUS, m.text
      assert Mutaruby::Parsing.valid?('c.rb', m.text), m.label
      prefix = CORPUS.lines.first(m.lineno - 1).join
      assert m.text.start_with?(prefix), m.label
    end
  end

  def test_a_mutant_equal_to_the_original_is_skipped
    assert_empty changes("def f\n  return nil\nend\n", 'return-nil')
    assert_empty changes("x if true\n", 'condition-true')
  end

  def test_identical_mutants_are_kept_once
    ms = muts("x = a || a\n", operators: %w[logical-drop-left logical-drop-right])
    assert_equal ['logical-drop-right'], ms.map(&:operator)
  end

  def test_occurrence_counts_stripped_lines
    src = "a = 1\nb = 2\n  a = 1\nc = 3\n"
    ms = muts(src, operators: ['literal-int']).select { |m| m.change == '1 => 2' }
    assert_equal [[1, 1, 'a = 1'], [3, 2, 'a = 1']], ms.map { |m| [m.lineno, m.occurrence, m.line_text] }
  end

  def test_mutations_are_built_once
    g = Mutaruby::Generator.new("def (\n", path: 'bad.rb')
    assert_same g.mutations, g.mutations
    assert_equal 1, g.errors.size
    g = Mutaruby::Generator.new("x = 1\n", path: 'ok.rb')
    assert_same g.mutations, g.mutations
  end

  def test_empty_and_comment_only_files
    assert_empty muts('')
    assert_empty muts("# nothing\n")
  end

  def test_strings_in_and_out_of_declarations
    assert_equal ["'x' => ''"], changes("def self.require = 'x'\n", 'literal-string')
    assert_equal ["'x' => ''"], changes("'x'\n", 'literal-string')
    assert_equal ["'x' => ''"], changes("foo('x')\n", 'literal-string')
    assert_empty changes("require 'x'\nraise 'y'\n", 'literal-string')
    assert_equal ['%q(abc) => %q()', '%Q[a] => %Q[]', "'x' => ''"],
                 changes("a = %q(abc)\nb = %Q[a]\nc = \"\#{'x'}\"\n", 'literal-string')
    assert_empty changes("a = ?a\nb = %w[p]\nc = <<~T\n  t\nT\nd = \"a\#{b}\"\n", 'literal-string')
  end

  def test_methods_after_a_singleton_class_are_instance_methods
    src = "class B\n  class << self\n    def t = 1\n  end\n  def after = 2\nend\n"
    assert_equal ['B.t', 'B#after'], muts(src, operators: ['literal-int']).map(&:method).uniq
  end

  def test_post_condition_loops_and_explicit_begin
    src = "begin\n  x\nend while a\nbegin\n  y\nend until b\n"
    assert_equal ['a => !(a)', 'b => !(b)'], changes(src, 'loop-condition-negate')
    assert_equal ['a => false'], changes(src, 'loop-condition-false')
    assert_equal ['a => nil', 'b => nil'], changes("begin\n  a\n  b\nend\n", 'statement-delete')
  end

  def test_which_symbols_are_mutated
    assert_equal [':a? => :__mutaruby__', ':b= => :__mutaruby__', ':C => :__mutaruby__'],
                 changes("x(:a?)\nx(:b=)\nx(:C)\nx(:+)\nx(:\"a b\")\nx(%s(q))\n", 'literal-symbol')
  end

  def test_collections_without_brackets_are_not_emptied
    assert_empty changes("a = 1, 2\nb = %w[p q]\nc = []\nd = [ ]\n", 'literal-array')
    assert_empty changes("f(a: 1)\nb = {}\nc = { }\n", 'literal-hash')
  end

  def test_compound_assignments
    assert_equal ['<<= => >>=', '>>= => <<=', '&= => |=', '/= => *='], changes("a <<= 1\na >>= 1\na &= b\na /= 2\n", 'op-assign')
    assert_empty changes("a **= 2\na %= 2\n", 'op-assign')
  end

  def test_one_argument_calls_are_not_operators
    %w[arithmetic comparison bitwise].each { |op| assert_empty changes("o.f(x)\nf(x)\n", op) }
  end

  def test_skipped_predicates
    assert_empty changes("x.frozen?\nx.respond_to?(:a)\nx.nil?\nrespond_to_missing?(:a, false)\n", 'predicate-true')
  end

  def test_operator_calls_and_writers_are_not_plain_calls
    assert_empty triples("x[1]\nx.y = 1\na + b\n").select { |op, _, _| op.start_with?('call-to', 'argument') }
    assert_equal ['a.() => a', 'a.(1) => a'], changes("a.()\na.(1)\n", 'call-to-receiver')
    assert_equal ['a.(1) => 1'], changes("a.()\na.(1)\n", 'call-to-argument')
  end

  def test_calls_inside_blocks
    assert_equal ['x.foo(1) => x'], changes("o.each { |x| x.foo(1) }\n", 'call-to-receiver')
    assert_equal ['o.map(&:x) => o'], changes("o.map(&:x)\n", 'call-to-receiver')
  end

  def test_argument_removal_limits
    assert_equal 6, Mutaruby::Generator::MAX_ARGS
    assert_equal ['a, b, c => b, c', 'a, b, c => a, c', 'a, b, c => a, b'], changes("f(a, b, c)\n", 'argument-removal')
    assert_equal 6, changes("f(a, b, c, d, e, g)\n", 'argument-removal').size
    assert_empty changes("f(a, b, c, d, e, g, h)\n", 'argument-removal')
    assert_equal ['x =>'], changes("a, b = foo(x)\n", 'argument-removal')
  end

  def test_float_edge_cases
    assert_equal ['0.00 => 1.0'], changes("x = 0.00\n", 'literal-float')
    assert_equal ['1e400 => 0.0'], changes("x = 1e400\n", 'literal-float')
  end

  def test_parenthesised_and_two_statement_bodies
    assert_empty changes("x = (a)\n", 'statement-delete')
    assert_equal ['a => nil', 'b => nil'], changes("x = (a; b)\n", 'statement-delete')
    assert_equal ['a => nil', 'b => nil'], changes("a\nb\n", 'statement-delete')
    assert_equal ['self.private => nil', 'private :x => nil', 'y => nil'],
                 changes("self.private\nprivate :x\nprivate\ny\n", 'statement-delete')
  end

  def test_method_bodies_of_singleton_predicates
    assert_equal ['x => true', 'x => false'], changes("def self.ok? = x\n", 'method-body-bool')
    assert_empty triples("def ok?; end\n")
  end

  # Regression: `parser` reads "\r\n" as "\n". Offsets must be mapped back to the file's own characters, or every
  # mutant after the first CRLF line break lands in the wrong place (the splice self-check used to abort the run).
  def test_crlf_sources
    src = "x = 1\r\ny = f(a,\r\n  b) + c\r\nz = 2\nw = 3\r\n"
    ms = muts(src)
    refute_empty ms
    ms.each do |m|
      assert Mutaruby::Parsing.valid?('c.rb', m.text), m.label
      assert_equal src.lines.first(m.lineno - 1).join, m.text.lines.first(m.lineno - 1).join, m.label
    end
    assert_equal "x = 1\r\ny = f(a,\r\n  b) - c\r\nz = 2\nw = 3\r\n", ms.find { |m| m.change == '+ => -' }.text
    assert_equal "x = 1\r\ny = f(a,\r\n  b) + c\r\nz = 2\nw = 4\r\n", ms.find { |m| m.change == '3 => 4' }.text
    assert_equal "x = 1\r\nnil\r\nz = 2\nw = 3\r\n", ms.find { |m| m.operator == 'statement-delete' && m.lineno == 2 }.text
    removed = ms.select { |m| m.operator == 'argument-removal' }.map(&:text)
    assert_includes removed, "x = 1\r\ny = f(b) + c\r\nz = 2\nw = 3\r\n"
    plus = ms.find { |m| m.change == '+ => -' }
    assert_equal ['b) + c', 3, 1], [plus.line_text, plus.lineno, plus.occurrence]
  end

  # A replacement that spans lines takes the file's line ending.
  def test_multiline_replacements_follow_the_line_ending
    crlf = "if a &&\r\n   b\r\n  x\r\nend\r\n"
    m = muts(crlf, operators: ['condition-negate']).first
    assert_equal "if !(a &&\r\n   b)\r\n  x\r\nend\r\n", m.text
    lf = crlf.delete("\r")
    assert_equal "if !(a &&\n   b)\n  x\nend\n", muts(lf, operators: ['condition-negate']).first.text
  end

  def test_block_removal
    assert_equal ['l.map { |x| x } => l.map', 'loop do x end => loop', 'l.each { _1 } => l.each'],
                 changes("l.map { |x| x }\nloop do\n  x\nend\nl.each { _1 }\n", 'block-removal')
  end

  def test_method_swap
    assert_equal ['first => last', 'min => max', 'any? => all?', 'select => reject', 'push => unshift'],
                 changes("a.first\na.min\na.any? { _1 }\na.select(&:x)\na.push(1)\n", 'method-swap')
    assert_empty changes("first\nselect(1)\n", 'method-swap')
    Mutaruby::Generator::METHOD_SWAPS.each do |from, to|
      assert Mutaruby::Generator::METHOD_SWAPS.key?(to), "#{to} has no swap back"
      assert_equal ["#{from} => #{to}"], changes("x.#{from}\n", 'method-swap')
    end
  end

  def test_element_removal_with_text
    assert_equal ['1, 2, 3 => 2, 3', '1, 2, 3 => 1, 3', '1, 2, 3 => 1, 2'], changes("x = [1, 2, 3]\n", 'element-removal')
    assert_equal ['a: 1, b: 2 => b: 2', 'a: 1, b: 2 => a: 1'], changes("x = { a: 1, b: 2 }\n", 'element-removal')
    assert_empty changes("x = [1]\ny = %w[a b]\nz = f(a: 1, b: 2)\nw = 1, 2\n", 'element-removal')
    assert_empty changes("x = [1, 2, 3, 4, 5, 6, 7]\n", 'element-removal')
    assert_equal 6, changes("x = [1, 2, 3, 4, 5, 6]\n", 'element-removal').size
  end

  def test_element_removal_with_unparser
    ms = Mutaruby::Generator.new("x = [1, 2]\ny = {a: 1, b: 2}\n", path: 's.rb', operators: ['element-removal'],
                                                                     renderer: :unparser).mutations
    assert_equal ['[1, 2] => [2]', '[1, 2] => [1]', '{a: 1, b: 2} => { b: 2 }', '{a: 1, b: 2} => { a: 1 }'],
                 ms.map(&:change)
    assert_equal "x = [2]\ny = {a: 1, b: 2}\n", ms.first.text
  end

  def test_regexp_yield_super
    assert_equal ['/a+/i => /(?!)/', '/x#{y}/ => /(?!)/'], changes("r = /a+/i\ns = /x\#{y}/\n", 'regexp-never-match')
    assert_equal ['yield => nil', 'yield(1) => nil'], changes("def f\n  yield\n  yield(1)\nend\n", 'yield-removal')
    assert_equal ['super => nil', 'super(1) => nil'], changes("def f\n  super\n  super(1)\nend\n", 'super-removal')
  end

  def test_clause_removal
    src = "case x\nwhen 1 then a\nwhen 2 then b\nend\n"
    assert_equal ['when 1 then a =>', 'when 2 then b =>'], changes(src, 'when-removal')
    assert_empty changes("case x\nwhen 1 then a\nend\n", 'when-removal'), 'a case needs a when'
    assert_empty changes("case x\nwhen 1 then a\nelse b\nend\n", 'when-removal')
    src = "begin\n  a\nrescue A\n  b\nrescue B\n  c\nend\n"
    assert_equal ['rescue A b =>', 'rescue B c =>'], changes(src, 'rescue-removal')
    m = muts(src, operators: ['rescue-removal']).first
    assert_equal "begin\n  a\n\nrescue B\n  c\nend\n", m.text
  end

  def test_nested_method_definitions
    src = "def outer\n  def inner\n    1\n  end\n  2\nend\n"
    ms = muts(src, operators: ['literal-int'])
    assert_equal [%w[1 inner], %w[2 outer]], ms.map { |m| [m.orig, m.method] }.uniq
  end

  def test_only_known_methods_are_swapped
    assert_empty changes("a.foo(1)\na.bar\n", 'method-swap')
  end

  def test_call_to_argument_takes_the_first_argument
    assert_equal ['o.f(a, b) => a'], changes("o.f(a, b)\n", 'call-to-argument')
  end
end
