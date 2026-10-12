# frozen_string_literal: true

Dir[File.join(__dir__, '{unit,e2e}', '*_test.rb')].sort.each { |f| require f }
