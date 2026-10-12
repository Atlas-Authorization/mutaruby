# frozen_string_literal: true

# mutaruby: mutation testing for Ruby. See README.md.
module Mutaruby
  class Error < StandardError; end
end

require_relative 'mutaruby/version'
require_relative 'mutaruby/parsing'
require_relative 'mutaruby/splicer'
require_relative 'mutaruby/mutation'
require_relative 'mutaruby/generator'
require_relative 'mutaruby/ignore_file'
require_relative 'mutaruby/sandbox'
require_relative 'mutaruby/command'
require_relative 'mutaruby/selection'
require_relative 'mutaruby/runner'
require_relative 'mutaruby/reporters'
require_relative 'mutaruby/cli'
