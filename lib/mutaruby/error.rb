# frozen_string_literal: true

module Mutaruby
  # A user-facing error: bad options, an invalid ignore file, a failing baseline. The CLI prints the message and exits 2.
  class Error < StandardError; end
end
