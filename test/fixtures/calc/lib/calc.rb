# frozen_string_literal: true

require_relative 'calc/helper'

# Café: the multi-byte characters in this comment and in the string below sit BEFORE most nodes on purpose
# (a byte-offset splice would put every mutant after them in the wrong place).
module Calc
  GREETING = 'naïve'

  module_function

  def add(a, b)
    a + b
  end

  def positive?(n)
    n > 0
  end

  # The `<` -> `<=` mutant of the guard is equivalent: for n == 0 both versions return 0.
  def clamp_low(n)
    return 0 if n < 0

    n
  end

  # Mutating `+=` into `-=` makes the loop run forever: that mutant is only killed by the timeout.
  def count_to(n)
    i = 0
    i += 1 while i < n
    i
  end

  def shout(word)
    Helper.upcase(word)
  end
end
