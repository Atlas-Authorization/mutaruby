# frozen_string_literal: true

require_relative '../test_helper'

class CoverageMapTest < Minitest::Test
  include TestHelpers

  C = Mutaruby::CoverageMap
  DATA = {
    'framework' => 'minitest',
    'tests' => { 'T#a' => { 'lib/x.rb' => [3, 4] }, 'T#b' => { 'lib/x.rb' => [4, 9], 'lib/y.rb' => [2] } },
    'load' => { 'lib/x.rb' => [1, 2] }
  }.freeze

  def test_probe_directory
    assert_equal File.expand_path('../../lib/mutaruby/probe', __dir__), C::PROBE_DIR
    assert File.file?(File.join(C::PROBE_DIR, 'mutaruby_probe.rb'))
  end

  def test_probe_env
    with_env('RUBYLIB' => nil, 'RUBYOPT' => nil) do
      assert_equal({ 'RUBYLIB' => C::PROBE_DIR, 'RUBYOPT' => '-rmutaruby_probe', 'X' => '1' }, C.probe_env('X' => '1'))
    end
    with_env('RUBYLIB' => '/a', 'RUBYOPT' => '-W0') do
      assert_equal({ 'RUBYLIB' => "#{C::PROBE_DIR}#{File::PATH_SEPARATOR}/a", 'RUBYOPT' => '-W0 -rmutaruby_probe' },
                   C.probe_env({}))
    end
    with_env('RUBYLIB' => '', 'RUBYOPT' => '') do
      assert_equal({ 'RUBYLIB' => C::PROBE_DIR, 'RUBYOPT' => '-rmutaruby_probe' }, C.probe_env({}))
    end
  end

  def test_tests_for
    m = C.new(DATA)
    assert_equal 'minitest', m.framework
    assert m.usable?
    assert_equal ['T#a'], m.tests_for('lib/x.rb', [3])
    assert_equal ['T#a', 'T#b'], m.tests_for('lib/x.rb', [4])
    assert_equal ['T#a', 'T#b'], m.tests_for('lib/x.rb', 3..9)
    assert_equal ['T#b'], m.tests_for('lib/y.rb', [2])
    assert_nil m.tests_for('lib/x.rb', [7]), 'a line no test reaches runs everything'
    assert_nil m.tests_for('lib/x.rb', [2, 3]), 'a load-time line runs everything'
    assert_nil m.tests_for('lib/z.rb', [3])
  end

  def test_usable
    refute C.new(DATA.merge('framework' => nil)).usable?
    refute C.new(DATA.merge('tests' => {})).usable?
    refute C.new(DATA.merge('tests' => { 'T#a' => {} })).usable?
  end

  def test_load
    Dir.mktmpdir do |d|
      path = File.join(d, 'c.json')
      File.binwrite(path, JSON.generate(DATA.merge('tests' => { "T#é" => { 'lib/x.rb' => [3] } })))
      verbose = $VERBOSE
      old = Encoding.default_external
      $VERBOSE = nil
      Encoding.default_external = Encoding::ISO_8859_1
      assert_equal ["T#é"], C.load(path).tests_for('lib/x.rb', [3])
    ensure
      Encoding.default_external = old
      $VERBOSE = verbose
    end
  end
end
