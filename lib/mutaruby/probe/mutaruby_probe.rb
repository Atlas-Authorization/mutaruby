# frozen_string_literal: true

# Loaded into the user's test process by mutaruby (RUBYLIB=<this directory>, RUBYOPT=-rmutaruby_probe) when
# coverage-based test selection is on. It depends on nothing from mutaruby itself and does nothing unless one of its
# environment variables is set:
#
#   MUTARUBY_COVERAGE_OUT=FILE   record, for every test, the lines of the project it executes (Ruby's Coverage API),
#                                and write them to FILE as JSON when the process exits
#   MUTARUBY_COVERAGE_ROOT=DIR   the project directory; only files below it are recorded
#   MUTARUBY_SELECT=FILE         run only the tests whose ids FILE lists, one per line
#
# The test command may start several Ruby processes (bundle exec -> rake -> ruby running the tests). Each loads the
# probe, but only the process that loads a test framework records or selects: launchers write nothing. That process
# then removes the variables, so Ruby processes started by the tests themselves run normally.
#
# Test ids: "Class#test_method" for Minitest, the example id ("./spec/a_spec.rb[1:2]") for RSpec.
module MutarubyProbe
  class << self
    attr_reader :framework

    def setup
      @out = ENV.fetch('MUTARUBY_COVERAGE_OUT', '')
      @select = ENV.fetch('MUTARUBY_SELECT', '')
      @installed = []
      return if @out.empty? && @select.empty?

      @select.empty? ? start_recording : load_selection
      Object.prepend(RequireHook)
      install_hooks
    end

    def recording? = !@out.empty?

    # --- recording -------------------------------------------------------------------------------------------------

    def start_recording
      require 'coverage'
      require 'json'
      root = ENV.fetch('MUTARUBY_COVERAGE_ROOT')
      @roots = [root, File.realpath(root)].uniq.map { |r| "#{r}/" }
      @tests = {}
      @load = {}
      @current = nil
      Coverage.start(lines: true)
      at_exit { write if @installed.any? }
    end

    # Lines run before a test starts (loading code, defining methods) count as load-time lines.
    def test_started(id)
      collect(@load)
      @current = id
    end

    def test_finished
      collect(@tests[@current] ||= {})
      @current = nil
    end

    def collect(into)
      Coverage.result(stop: false, clear: true).each do |path, data|
        rel = relative(path)
        next unless rel

        lines = data[:lines]
        hit = lines.each_index.select { |i| lines[i].to_i.positive? }.map { |i| i + 1 }
        (into[rel] ||= []).concat(hit) unless hit.empty?
      end
    end

    def relative(path)
      [path, (File.realpath(path) rescue path)].each do |p| # rubocop:disable Style/RescueModifier
        root = @roots.find { |r| p.start_with?(r) }
        return p.delete_prefix(root) if root
      end
      nil
    end

    def write
      collect(@load)
      squash = ->(h) { h.transform_values { |l| l.uniq.sort } }
      File.write(@out, JSON.generate(framework: @installed.first, tests: @tests.transform_values(&squash),
                                     load: squash.call(@load)))
    end

    # --- selection -------------------------------------------------------------------------------------------------

    def load_selection
      @selected = File.readlines(@select, chomp: true).to_h { |id| [id, true] }
    end

    def selected?(id) = @selected.key?(id)

    # --- frameworks ------------------------------------------------------------------------------------------------

    def install_hooks
      install_minitest if !@installed.include?('minitest') && defined?(::Minitest::Test)
      install_rspec if !@installed.include?('rspec') && defined?(::RSpec) && ::RSpec.respond_to?(:configure)
    end

    # The first framework found: this is the test process. Its children must not record or select.
    def claim
      %w[MUTARUBY_COVERAGE_OUT MUTARUBY_COVERAGE_ROOT MUTARUBY_SELECT].each { |k| ENV.delete(k) }
    end

    def install_minitest
      claim
      @installed << 'minitest'
      if recording?
        ::Minitest::Test.prepend(MinitestRecording)
      else
        ::Minitest::Test.singleton_class.prepend(MinitestSelection)
      end
    end

    def install_rspec
      claim
      @installed << 'rspec'
      if recording?
        ::RSpec.configure do |c|
          c.around(:example) do |ex|
            MutarubyProbe.test_started(ex.id)
            ex.run
          ensure
            MutarubyProbe.test_finished
          end
        end
      else
        ::RSpec.configure do |c|
          c.define_derived_metadata do |meta|
            meta[:mutaruby_selected] = true if MutarubyProbe.selected?("#{meta[:rerun_file_path]}[#{meta[:scoped_id]}]")
          end
          c.filter_run_including(mutaruby_selected: true)
        end
      end
    end
  end

  # Re-checks for test frameworks after every require: they are loaded after this file.
  module RequireHook
    private

    def require(name)
      super
    ensure
      MutarubyProbe.install_hooks
    end
  end

  module MinitestRecording
    def before_setup
      MutarubyProbe.test_started("#{self.class.name}##{name}")
      super
    end

    def after_teardown
      super
    ensure
      MutarubyProbe.test_finished
    end
  end

  module MinitestSelection
    def runnable_methods
      super.select { |m| MutarubyProbe.selected?("#{name}##{m}") }
    end
  end
end

MutarubyProbe.setup
