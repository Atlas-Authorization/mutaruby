# frozen_string_literal: true

require_relative '../test_helper'

class ConstantsTest < Minitest::Test
  # Every constant collection of the library is frozen (shared, never modified).
  def test_constant_collections_are_frozen
    seen = []
    walk = lambda do |mod|
      mod.constants(false).each do |c|
        v = mod.const_get(c)
        if v.is_a?(Module)
          walk.call(v) if v.name&.start_with?('Mutaruby') && !seen.include?(v) && seen << v
        elsif v.is_a?(Array) || v.is_a?(Hash) || v.is_a?(String)
          assert v.frozen?, "#{mod}::#{c} is not frozen"
          seen << c
        end
      end
    end
    walk.call(Mutaruby)
    %i[OPERATORS SWAPS OP_ASSIGN DECLARATIONS VISIBILITY_CALLS STRUCTURAL PREDICATE_SKIP DEFAULT_EXCLUDES
       DEFAULT_PATTERNS KEYS REQUIRED STRINGS MARK].each { |c| assert_includes seen, c }
  end
end
