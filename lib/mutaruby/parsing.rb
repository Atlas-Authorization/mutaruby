# frozen_string_literal: true

require 'parser'

module Mutaruby
  # Picks the newest `parser` grammar that is not newer than the running Ruby. `parser/current` prints a warning on
  # Rubies it does not know yet; choosing the class ourselves keeps the output clean and the behaviour explicit.
  module Parsing
    class << self
      def parser_class
        @parser_class ||= begin
          major, minor = RUBY_VERSION.split('.').map(&:to_i)
          wanted = (major * 10) + minor
          found = nil
          wanted.downto(31) do |v|
            begin
              require "parser/ruby#{v}"
              found = Parser.const_get("Ruby#{v}")
              break
            rescue LoadError, NameError
              next
            end
          end
          found || raise(Error, "no parser grammar available for Ruby #{RUBY_VERSION}")
        end
      end

      def buffer(path, source)
        Parser::Source::Buffer.new(path, source: source)
      end

      # Parse `source`; returns the AST or raises Parser::SyntaxError.
      def parse(path, source)
        p = parser_class.new
        p.diagnostics.all_errors_are_fatal = true
        p.diagnostics.ignore_warnings = true
        p.parse(buffer(path, source))
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
