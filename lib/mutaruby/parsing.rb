# frozen_string_literal: true

require 'parser'
require_relative 'error'

module Mutaruby
  # Picks the newest `parser` grammar that is not newer than the running Ruby. `parser/current` prints a warning on
  # Rubies it does not know yet; choosing the class ourselves keeps the output clean and the behaviour explicit.
  module Parsing
    OLDEST = 31 # Ruby 3.1

    class << self
      def parser_class
        @parser_class ||= grammar_for(RUBY_VERSION)
      end

      # The parser class for a Ruby version string ("3.3.5" -> Parser::Ruby33), falling back to older grammars.
      def grammar_for(version)
        major, minor = version.split('.').map(&:to_i)
        ((major * 10) + minor).downto(OLDEST) do |v|
          require "parser/ruby#{v}"
          return Parser.const_get("Ruby#{v}")
        rescue LoadError
          # this `parser` release has no grammar for v; try the next older one
        end
        raise Error, "no parser grammar available for Ruby #{version}"
      end

      # Parse `source`; returns the AST or raises Parser::SyntaxError.
      def parse(path, source)
        p = parser_class.new
        p.diagnostics.all_errors_are_fatal = true
        p.parse(Parser::Source::Buffer.new(path, source: source))
      end

      def valid?(path, source)
        parse(path, source)
        true
      rescue Parser::SyntaxError, EncodingError, ArgumentError
        false
      end
    end
  end
end
