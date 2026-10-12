# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/calc'

class TestCalc < Minitest::Test
  def test_add
    assert_equal 5, Calc.add(2, 3)
  end

  def test_positive
    assert Calc.positive?(1)
    refute Calc.positive?(0)
  end

  def test_clamp_low
    assert_equal 0, Calc.clamp_low(-4)
    assert_equal 0, Calc.clamp_low(-1)
    assert_equal 0.5, Calc.clamp_low(0.5)
    assert_equal 0, Calc.clamp_low(0)
    assert_equal 7, Calc.clamp_low(7)
  end

  def test_count_to
    assert_equal 3, Calc.count_to(3)
    assert_equal 0, Calc.count_to(0)
    assert_equal 0, Calc.count_to(-2)
  end

  def test_shout
    assert_equal 'HI', Calc.shout('hi')
  end
end
