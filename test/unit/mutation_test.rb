# frozen_string_literal: true

require_relative '../test_helper'

class MutationTest < Minitest::Test
  M = Mutaruby::Mutation

  def mk(**kw)
    M.new(id: 3, file: 'lib/a.rb', operator: 'comparison', orig: '>', repl: '>=', lineno: 2, line_text: 'a > b',
          occurrence: 1, method: 'A#f', text: "x\na >= b\n", **kw)
  end

  def test_squeeze
    assert_equal 'a b c', M.squeeze("  a \n\t b  c\n")
    assert_equal '', M.squeeze(" \n ")
  end

  def test_label_is_one_line_and_cut_at_80
    assert_equal 80, Mutaruby::LABEL_MAX
    assert_equal 'comparison: > => >=', mk.label
    assert_equal 'statement-delete: a b => nil', mk(operator: 'statement-delete', orig: "a\n  b", repl: 'nil').label
    s80 = 'x' * 80
    assert_equal "o: #{s80} => y", mk(operator: 'o', orig: s80, repl: 'y').label
    assert_equal "o: a#{'x' * 76}... => y", mk(operator: 'o', orig: "a#{s80}", repl: 'y').label
    assert_equal "o: a => #{'b' * 77}...", mk(operator: 'o', orig: 'a', repl: 'b' * 90).label
  end

  # Regression: removing the only argument gives an empty replacement; the change text must survive the ignore
  # file's whitespace normalisation unchanged ("word =>", not "word => ").
  def test_change
    assert_equal '> => >=', mk.change
    assert_equal 'a b => nil', mk(orig: "a\n   b", repl: 'nil').change
    assert_equal 'word =>', mk(orig: 'word', repl: '').change
    assert_equal 'f(a, b) => f(b)', mk(orig: "f(a,\n  b)", repl: 'f(b)').change
  end

  def test_location_and_hash
    assert_equal 'lib/a.rb:2', mk.location
    assert_equal({ id: 3, file: 'lib/a.rb', lineno: 2, operator: 'comparison', method: 'A#f', line_text: 'a > b',
                   occurrence: 1, orig: '>', repl: '>=', change: '> => >=', label: 'comparison: > => >=' }, mk.to_h)
  end

  def test_diff
    assert_equal "- a > b\n+ a >= b", mk.diff("x\na > b\n")
    multi = mk(lineno: 1, orig: "foo(1,\n  2)", repl: 'nil', text: "nil\nz\n")
    assert_equal "- foo(1,\n-   2)\n+ nil", multi.diff("foo(1,\n  2)\nz\n")
    grow = mk(lineno: 1, orig: 'a', repl: "b(\n)", text: "b(\n)\nz\n")
    assert_equal "- a\n+ b(\n+ )", grow.diff("a\nz\n")
  end
end
