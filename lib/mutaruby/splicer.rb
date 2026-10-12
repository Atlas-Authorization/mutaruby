# frozen_string_literal: true

module Mutaruby
  # Raised when a splice would not replace exactly the node's own source. Aborts the whole run: a mutant placed at
  # the wrong offset tests nothing, and if it "survives" it reports a test gap that does not exist.
  class SpliceError < StandardError; end

  # Replaces source[begin_pos...end_pos] with a replacement.
  #
  # The `parser` gem reports CHARACTER offsets, so the slice is taken by characters. Slicing by bytes would shift every
  # mutant after the first multi-byte character in the file (an accented letter in a comment is enough) onto the wrong
  # text. The self-check makes that class of bug (bytes vs characters, a stale buffer, a wrong range) fail loudly:
  # the slice being replaced must be exactly the node's own source text, or nothing is spliced.
  module Splicer
    module_function

    def splice(source, begin_pos, end_pos, expected, replacement)
      actual = source[begin_pos...end_pos]
      unless actual == expected
        raise SpliceError, "splice self-check failed at offsets #{begin_pos}...#{end_pos}: " \
                           "the slice is #{actual.inspect}, the node's source is #{expected.inspect}"
      end

      source[0...begin_pos] + replacement + source[end_pos..]
    end
  end
end
