# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'open3'

# The probe runs inside the user's test process; these tests run it there, in a child Ruby.
class ProbeTest < Minitest::Test
  include TestHelpers

  LIB = <<~RUBY
    module W
      def self.a(x)
        x + 1
      end

      def self.b(x)
        x * 2
      end
    end
  RUBY

  MINITEST = <<~RUBY
    require 'minitest/autorun'
    require_relative '../lib/w'
    Minitest.after_run { W.a(1) }

    class WTest < Minitest::Test
      def setup
        File.write(File.join(ENV['LOG'], name), '') if ENV['LOG']
      end

      def test_a
        assert_equal 2, W.a(1)
      end

      def test_b
        assert_equal 4, W.b(2)
      end
    end
  RUBY

  SPEC = <<~RUBY
    require_relative '../lib/w'

    RSpec.describe W do
      before { File.write(File.join(ENV['LOG'], RSpec.current_example.id.tr('/[]:.', '_____')), '') if ENV['LOG'] }

      it('adds') { expect(W.a(1)).to eq(2) }

      describe '.b' do
        it('doubles') { expect(W.b(2)).to eq(4) }
      end
    end
  RUBY

  def project
    with_project('lib/w.rb' => LIB, 'test/w_test.rb' => MINITEST, 'spec/w_spec.rb' => SPEC) { |root| yield root }
  end

  def run_probe(root, env, *cmd, chdir: root)
    env = Mutaruby::CoverageMap.probe_env(env)
    out, st = Open3.capture2e(env, RbConfig.ruby, *cmd, chdir: chdir)
    assert st.success?, out
    out
  end

  def rspec!
    Gem::Specification.find_by_name('rspec-core')
  rescue Gem::MissingSpecError
    skip 'rspec-core is not installed'
  end

  def record(root, *cmd, chdir: root, coverage_root: root)
    out = File.join(root, '..', 'cov.json')
    run_probe(root, { 'MUTARUBY_COVERAGE_OUT' => out, 'MUTARUBY_COVERAGE_ROOT' => coverage_root }, *cmd, chdir: chdir)
    JSON.parse(File.read(out))
  end

  def selected(root, ids, *cmd)
    Dir.mktmpdir do |log|
      list = File.join(root, '..', 'sel.txt')
      File.write(list, ids.map { |i| "#{i}\n" }.join)
      run_probe(root, { 'MUTARUBY_SELECT' => list, 'LOG' => log }, *cmd)
      Dir.children(log).sort
    end
  end

  def test_records_minitest_coverage_per_test
    project do |root|
      data = record(root, 'test/w_test.rb')
      assert_equal 'minitest', data['framework']
      # (Ruby 3.1 does not cover the main script, test/w_test.rb here; later versions do.)
      assert_equal [3], data['tests']['WTest#test_a']['lib/w.rb']
      assert_equal [7], data['tests']['WTest#test_b']['lib/w.rb']
      assert_equal [7, 15], data['tests']['WTest#test_b']['test/w_test.rb'] if RUBY_VERSION >= '3.2'
      assert_equal %w[WTest#test_a WTest#test_b], data['tests'].keys.sort
      # load-time lines, plus line 3 run by an after_run hook once the tests are over (kept sorted)
      assert_equal [1, 2, 3, 6], data['load']['lib/w.rb']
      assert_equal [], data['load'].keys - ['lib/w.rb', 'test/w_test.rb'], 'nothing outside the project'
    end
  end

  # Coverage reports real paths; a project root reached through a symlink still maps to relative paths.
  def test_records_through_a_symlinked_root
    posix_only!
    project do |root|
      link = File.join(root, '..', 'link')
      File.symlink(root, link)
      data = record(root, File.join(link, 'test/w_test.rb'), chdir: link, coverage_root: link)
      assert_equal [3], data['tests']['WTest#test_a']['lib/w.rb']
    end
  end

  def test_selects_minitest_tests
    project do |root|
      assert_equal ['test_b'], selected(root, ['WTest#test_b'], 'test/w_test.rb')
      assert_equal %w[test_a test_b], selected(root, ['WTest#test_a', 'WTest#test_b'], 'test/w_test.rb')
      assert_equal [], selected(root, ['Other#test_a'], 'test/w_test.rb')
    end
  end

  def test_records_rspec_coverage_per_example
    rspec!
    project do |root|
      data = record(root, '-S', 'rspec', 'spec/w_spec.rb')
      assert_equal 'rspec', data['framework']
      assert_equal %w[./spec/w_spec.rb[1:1] ./spec/w_spec.rb[1:2:1]], data['tests'].keys.sort
      assert_equal [3], data['tests']['./spec/w_spec.rb[1:1]']['lib/w.rb']
      assert_equal [7], data['tests']['./spec/w_spec.rb[1:2:1]']['lib/w.rb']
    end
  end

  def test_selects_rspec_examples
    rspec!
    project do |root|
      assert_equal ['__spec_w_spec_rb_1_2_1_'], selected(root, ['./spec/w_spec.rb[1:2:1]'], '-S', 'rspec', 'spec/w_spec.rb')
      assert_equal [], selected(root, ['./spec/other.rb[1:1]'], '-S', 'rspec', 'spec/w_spec.rb')
    end
  end

  # Each framework is hooked once, however many files are required afterwards.
  def test_hooks_are_installed_once
    project do |root|
      check = File.join(root, 'check.rb')
      File.write(check, <<~RUBY)
        require 'minitest'
        require 'set'
        require 'json'
        installed = MutarubyProbe.instance_variable_get(:@installed)
        exit(installed == ['minitest'] && Minitest::Test.ancestors.count(MutarubyProbe::MinitestRecording) == 1 ? 0 : 1)
      RUBY
      record(root, check)
    end
  end

  def test_rspec_hook_is_installed_once
    rspec!
    project do |root|
      check = File.join(root, 'check.rb')
      File.write(check, <<~RUBY)
        require 'rspec/core'
        require 'set'
        hooks = RSpec.configuration.hooks.send(:hooks_for, :around, :example)
        exit(MutarubyProbe.instance_variable_get(:@installed) == ['rspec'] && hooks.items_and_filters.count { |item, _| item.block.source_location.first.end_with?('mutaruby_probe.rb') } == 1 ? 0 : 1)
      RUBY
      record(root, check)
    end
  end

  # Without its variables the probe changes nothing.
  def test_inert_without_its_variables
    project do |root|
      check = File.join(root, 'check.rb')
      File.write(check, "exit(defined?(MutarubyProbe) && !Object.ancestors.include?(MutarubyProbe::RequireHook) ? 0 : 1)\n")
      run_probe(root, {}, check)
    end
  end

  # A failing require still lets later framework loads be hooked.
  def test_hooks_survive_a_failing_require
    project do |root|
      check = File.join(root, 'check.rb')
      File.write(check, <<~RUBY)
        begin
          require 'no_such_library_anywhere'
        rescue LoadError
          nil
        end
        require 'minitest'
        exit(MutarubyProbe.instance_variable_get(:@installed) == ['minitest'] ? 0 : 1)
      RUBY
      record(root, check)
    end
  end

  NESTED = <<~RUBY
    require 'minitest/autorun'
    require 'open3'
    require 'rbconfig'

    class NestedTest < Minitest::Test
      def test_runs_another_suite
        out, = Open3.capture2e(RbConfig.ruby, 'test/w_test.rb')
        assert_match(/2 runs, 2 assertions, 0 failures/, out)
      end
    end
  RUBY

  # Ruby processes started by the tests run normally: they neither record nor select.
  def test_processes_started_by_tests_are_left_alone
    project do |root|
      File.write(File.join(root, 'test/nested_test.rb'), NESTED)
      data = record(root, 'test/nested_test.rb')
      assert_equal ['NestedTest#test_runs_another_suite'], data['tests'].keys
      assert_equal 'minitest', data['framework']
      selected(root, ['NestedTest#test_runs_another_suite'], 'test/nested_test.rb')
    end
  end

  # A launcher (rake, bundle exec) loads the probe too but no framework: the test process it starts records, and the
  # launcher does not overwrite what it wrote.
  def test_launchers_write_nothing
    project do |root|
      launcher = File.join(root, 'launch.rb')
      File.write(launcher, "require 'rbconfig'\nexit(system(RbConfig.ruby, 'test/w_test.rb') ? 0 : 1)\n")
      data = record(root, launcher)
      assert_equal %w[WTest#test_a WTest#test_b], data['tests'].keys.sort
      Dir.mktmpdir do |d|
        out = File.join(d, 'none.json')
        run_probe(root, { 'MUTARUBY_COVERAGE_OUT' => out, 'MUTARUBY_COVERAGE_ROOT' => root }, '-e', 'exit 0')
        refute File.exist?(out), 'a process without tests writes no map'
      end
    end
  end

  GONE = <<~RUBY
    require 'minitest/autorun'
    tmp = File.join(__dir__, '..', ENV.fetch('GONE_DIR'), 'tmp.rb')
    FileUtils.mkdir_p(File.dirname(tmp))
    File.write(tmp, "module Tmp\n  def self.x\n    1\n  end\nend\n")
    require tmp
    File.delete(tmp)
    FileUtils.rm_rf(File.dirname(tmp)) if ENV['GONE_DIR'] == 'gone'

    class GoneTest < Minitest::Test
      def test_x
        assert_equal 1, Tmp.x
      end
    end
  RUBY

  # Files that were loaded and then deleted (with or without their directory) are still mapped.
  def test_records_deleted_files
    project do |root|
      File.write(File.join(root, 'test/gone_test.rb'), "require 'fileutils'\n#{GONE}")
      data = with_env('GONE_DIR' => 'lib') { record(root, 'test/gone_test.rb') }
      assert_equal [3], data['tests']['GoneTest#test_x']['lib/tmp.rb']
      data = with_env('GONE_DIR' => 'gone') { record(root, File.join(File.realpath(root), 'test/gone_test.rb')) }
      assert_equal [3], data['tests']['GoneTest#test_x']['gone/tmp.rb']
    end
  end

  # Coverage reports real paths for files loaded by their real path; a root given through a symlink still matches.
  def test_records_real_paths_under_a_symlinked_root
    posix_only!
    project do |root|
      link = File.join(root, '..', 'link')
      File.symlink(root, link)
      data = record(root, File.join(File.realpath(root), 'test/w_test.rb'), coverage_root: link)
      assert_equal [3], data['tests']['WTest#test_a']['lib/w.rb']
    end
  end

  # When the first test framework loaded is Minitest, the map says so, even if RSpec is loaded later.
  def test_the_first_framework_loaded_is_recorded
    rspec!
    project do |root|
      both = File.join(root, 'test/both_test.rb')
      File.write(both, "require 'rspec/core'\n#{MINITEST.sub("require_relative '../lib/w'", "require_relative '../lib/w'\nrequire 'rspec/core'")}")
      data = record(root, File.join(root, 'test/w_test.rb'))
      assert_equal 'minitest', data['framework']
      data = record(root, both)
      assert_equal 'rspec', data['framework']
    end
  end

  # Lifecycle hooks of other libraries (included into Minitest::Test, so after the probe) still run.
  def test_other_after_teardown_hooks_still_run
    project do |root|
      check = File.join(root, 'test/hook_test.rb')
      File.write(check, <<~RUBY)
        require 'minitest/autorun'

        module Marker
          def before_setup
            File.write("\#{ENV.fetch('MARK')}.setup", name)
            super
          end

          def after_teardown
            File.write(ENV.fetch('MARK'), name)
            super
          end
        end
        Minitest::Test.include(Marker)

        class HookTest < Minitest::Test
          def test_x
            assert true
          end
        end
      RUBY
      Dir.mktmpdir do |d|
        mark = File.join(d, 'mark')
        with_env('MARK' => mark) { record(root, 'test/hook_test.rb') }
        assert_equal 'test_x', File.read(mark)
        assert_equal 'test_x', File.read("#{mark}.setup")
      end
    end
  end

  NESTED_SPEC = <<~RUBY
    require 'open3'
    require 'rbconfig'

    RSpec.describe 'a suite that runs another' do
      it('runs it in full') do
        out, = Open3.capture2e(RbConfig.ruby, '-S', 'rspec', 'spec/w_spec.rb')
        expect(out).to include('2 examples, 0 failures')
      end
    end
  RUBY

  def test_processes_started_by_rspec_examples_are_left_alone
    rspec!
    project do |root|
      File.write(File.join(root, 'spec/nested_spec.rb'), NESTED_SPEC)
      data = record(root, '-S', 'rspec', 'spec/nested_spec.rb')
      assert_equal ['./spec/nested_spec.rb[1:1]'], data['tests'].keys
      Dir.mktmpdir do |log|
        list = File.join(root, '..', 'sel.txt')
        File.write(list, "./spec/nested_spec.rb[1:1]\n")
        out = run_probe(root, { 'MUTARUBY_SELECT' => list, 'LOG' => log }, '-S', 'rspec', 'spec/nested_spec.rb')
        assert_includes out, '1 example, 0 failures'
      end
    end
  end
end
