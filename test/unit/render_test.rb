# frozen_string_literal: true

require_relative '../test_helper'

class RenderTest < Minitest::Test
  def test_unparse_without_an_element
    assert_equal '[1, 3]', Mutaruby::Render.unparse('[1, 2, 3]', 1)
    assert_equal '{ b: 2 }', Mutaruby::Render.unparse('{a: 1, b: 2}', 0)
  end

  def test_missing_unparser_is_a_clear_error
    Mutaruby::Render.singleton_class.alias_method(:real_require, :require)
    Mutaruby::Render.define_singleton_method(:require) { |*| raise LoadError, 'cannot load such file -- unparser' }
    err = assert_raises(Mutaruby::Render::Unavailable) { Mutaruby::Render.unparse('[1, 2]', 0) }
    assert_equal '--unparser needs the unparser gem (gem install unparser)', err.message
    assert_kind_of Mutaruby::Error, err
  ensure
    Mutaruby::Render.singleton_class.alias_method(:require, :real_require)
    Mutaruby::Render.singleton_class.remove_method(:real_require)
  end
end
