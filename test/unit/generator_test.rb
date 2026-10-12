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
    assert_equal ['a => '], changes("o.f(a)\n", 'argument-removal')
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
end
