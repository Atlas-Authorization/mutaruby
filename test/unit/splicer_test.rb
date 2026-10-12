# frozen_string_literal: true

require_relative '../test_helper'

class SplicerTest < Minitest::Test
  include TestHelpers

  def test_splices_at_character_offsets
    src = "# é\nx = 1 + 2\n"
    b = src.index('+')
    assert_equal "# é\nx = 1 - 2\n", Mutaruby::Splicer.splice(src, b, b + 1, '+', '-')
  end

  # Regression: offsets are CHARACTER offsets. Byte offsets after a multi-byte character point at the wrong text,
  # and the self-check must refuse the splice instead of silently mutating the wrong place.
  def test_self_check_rejects_byte_offsets
    src = "# é\nx = 1 + 2\n"
    b = src.b.index('+')
    refute_equal src.index('+'), b
    err = assert_raises(Mutaruby::SpliceError) { Mutaruby::Splicer.splice(src, b, b + 1, '+', '-') }
    assert_match(/self-check failed/, err.message)
  end

  def test_self_check_rejects_a_stale_expected_text
    assert_raises(Mutaruby::SpliceError) { Mutaruby::Splicer.splice('a + b', 2, 3, '-', '*') }
  end

  def test_keeps_everything_outside_the_slice
    src = "αβγ = [1, 2]\n# ü\n"
    b = src.index('2')
    out = Mutaruby::Splicer.splice(src, b, b + 1, '2', 'nil')
    assert_equal "αβγ = [1, nil]\n# ü\n", out
  end

  # Regression: every mutant of a file with multi-byte characters before the code replaces exactly its node.
  def test_generator_mutants_after_multibyte_text_are_placed_on_their_node
    src = "# Café — ü\nS = 'naïve'\ndef f(a)\n  a > 1 && a < 9\nend\n"
    ms = muts(src)
    refute_empty ms
    ms.each do |m|
      line = src.lines[m.lineno - 1]
      assert_includes line, m.orig.lines.first.chomp, "#{m.label} is not on line #{m.lineno}"
      prefix = src.lines.first(m.lineno - 1).join
      assert m.text.start_with?(prefix), "#{m.label} changed text before its line"
    end
    assert_includes ms.map(&:change), '> => >='
  end
end
