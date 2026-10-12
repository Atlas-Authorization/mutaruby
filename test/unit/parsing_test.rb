# frozen_string_literal: true

require_relative '../test_helper'

class ParsingTest < Minitest::Test
  P = Mutaruby::Parsing

  def test_grammar_for_a_ruby_version
    assert_equal 31, P::OLDEST
    assert_equal 'Parser::Ruby31', P.grammar_for('3.1.0').name
    assert_equal 'Parser::Ruby32', P.grammar_for('3.2.3').name
    assert_equal 'Parser::Ruby33', P.grammar_for('3.3.10').name
  end

  # A Ruby newer than the newest grammar of the installed `parser` falls back to that newest grammar.
  def test_newer_rubies_fall_back
    newest = (31..99).select do |v|
      require "parser/ruby#{v}"
      true
    rescue LoadError
      false
    end.max
    assert_equal Parser.const_get("Ruby#{newest}"), P.grammar_for('9.9.0')
  end

  def test_too_old_rubies_are_refused
    %w[3.0.7 2.7.0 2.0.0 1.9.3].each do |v|
      err = assert_raises(Mutaruby::Error) { P.grammar_for(v) }
      assert_equal "no parser grammar available for Ruby #{v}", err.message
    end
  end

  def test_parser_class_is_the_running_rubys_grammar_computed_once
    assert_equal P.grammar_for(RUBY_VERSION), P.parser_class
    saved = P.parser_class
    P.instance_variable_set(:@parser_class, :memoised)
    assert_equal :memoised, P.parser_class
  ensure
    P.instance_variable_set(:@parser_class, saved)
  end

  def test_parse_and_valid
    ast = P.parse('f.rb', "a + 1\n")
    assert_equal :send, ast.type
    assert_equal 'f.rb', ast.loc.expression.source_buffer.name
    assert_equal true, P.valid?('f.rb', "a + 1\n")
    assert_equal false, P.valid?('f.rb', "a +\n")
    assert_equal false, P.valid?('f.rb', "def (\n")
    assert_raises(Parser::SyntaxError) { P.parse('f.rb', "a +\n") }
  end
end
