# frozen_string_literal: true

# Runs the unit suite (the fast tests; also the oracle when mutaruby mutates itself).
Dir[File.join(__dir__, 'unit', '*_test.rb')].sort.each { |f| require f }
