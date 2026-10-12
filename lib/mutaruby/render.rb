# frozen_string_literal: true

require_relative 'error'

module Mutaruby
  # Renders rebuilt nodes back to Ruby source with the MIT-licensed `unparser` gem (optional: `gem install unparser`).
  # Text splicing stays the default; this path is used, with --unparser, for operators that rebuild a node. The
  # rendered text is still spliced over the node's own range, so the splice self-check applies as usual.
  module Render
    class Unavailable < Error; end

    module_function

    def load!
      require 'unparser'
    rescue LoadError
      raise Unavailable, '--unparser needs the unparser gem (gem install unparser)'
    end

    # `source` (an array or hash literal) without its element number `index`, rendered by unparser. The node is
    # parsed again by unparser itself, so its AST is in the form unparser expects.
    def unparse(source, index)
      load!
      node = Unparser.parse(source)
      Unparser.unparse(node.updated(nil, node.children.reject.with_index { |_, j| j == index }))
    end
  end
end
