# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'

class SelectionTest < Minitest::Test
  include TestHelpers

  FILES = { 'lib/a.rb' => "def f(x)\n  x + 1\nend\n", 'lib/sub/b.rb' => "def g(y)\n  y * 2\nend\n", 'app/c.rb' => "1\n" }.freeze

  def sel(root, **kw) = Mutaruby::Selection.new(root: root, **kw)

  def mutations
    [Mutaruby::Generator.new(FILES['lib/a.rb'], path: 'lib/a.rb').mutations,
     Mutaruby::Generator.new(FILES['lib/sub/b.rb'], path: 'lib/sub/b.rb').mutations].flatten
  end

  def test_default_and_explicit_patterns
    with_project(FILES) do |root|
      assert_equal ['lib/a.rb', 'lib/sub/b.rb'], sel(root).files
      assert_equal ['app/c.rb', 'lib/a.rb'], sel(root, patterns: ['./lib/a.rb', 'app/*.rb', 'lib/a.rb']).files
      assert_equal ['lib/sub/b.rb'], sel(root, patterns: [File.join(root, 'lib/sub/b.rb')]).files
      assert_empty sel(root, patterns: ['nothing/**/*.rb']).files
    end
  end

  def test_line_specs
    s = Mutaruby::Selection.parse_line_spec('lib/a.rb:2-4')
    assert_equal ['lib/a.rb', 2, 4], [s.file, s.from, s.to]
    s = Mutaruby::Selection.parse_line_spec('./lib/a.rb:7')
    assert_equal ['lib/a.rb', 7, 7], [s.file, s.from, s.to]
    s = Mutaruby::Selection.parse_line_spec('3-5')
    assert_equal [nil, 3, 5], [s.file, s.from, s.to]
    assert_raises(Mutaruby::Error) { Mutaruby::Selection.parse_line_spec('x') }
    assert_raises(Mutaruby::Error) { Mutaruby::Selection.parse_line_spec('5-3') }
  end

  def test_shard_spec
    assert_equal [2, 3], Mutaruby::Selection.parse_shard('2/3')
    %w[0/3 4/3 1/0 a/b 3].each { |bad| assert_raises(Mutaruby::Error, bad) { Mutaruby::Selection.parse_shard(bad) } }
  end

  def test_shards_partition_the_mutants
    ms = mutations
    n = 3
    parts = (1..n).map { |i| sel('.', shard: [i, n]).filter(ms) }
    assert_equal ms.map(&:object_id).sort, parts.flatten.map(&:object_id).sort
    assert(parts.all? { |p| p.size >= ms.size / n })
    refute sel('.', shard: [1, 2]).complete?
    assert sel('.').complete?
  end

  def test_method_filters
    ms = mutations
    only_f = sel('.', methods: ['f']).filter(ms)
    refute_empty only_f
    assert(only_f.all? { |m| m.method == 'f' })
    assert(sel('.', exclude_methods: ['f']).filter(ms).none? { |m| m.method == 'f' })
    assert_equal ms.size, sel('.', methods: ['*']).filter(ms).size
    top = Mutaruby::Generator.new("x = 1\n", path: 't.rb').mutations
    assert_empty sel('.', methods: ['*']).filter(top)
    q = Mutaruby::Generator.new("class K\n  def m\n    1\n  end\nend\n", path: 'k.rb').mutations
    assert_equal q.size, sel('.', methods: ['K#*']).filter(q).size
    assert_equal q.size, sel('.', methods: ['m']).filter(q).size
    assert_empty sel('.', methods: ['K.m']).filter(q)
  end

  def test_line_filters
    ms = mutations
    on2 = sel('.', lines: ['lib/a.rb:2']).filter(ms)
    refute_empty on2
    assert(on2.all? { |m| m.file == 'lib/a.rb' && m.lineno == 2 })
    assert(sel('.', lines: ['2']).filter(ms).map(&:file).uniq.size == 2)
    assert(sel('.', exclude_lines: ['1-1']).filter(ms).none? { |m| m.lineno == 1 })
    assert_equal ms.size, sel('.', exclude_lines: ['lib/zzz.rb:1-99']).filter(ms).size
  end

  def test_since_uses_git_diff_and_untracked_files
    skip 'git not available' unless system('git --version', out: File::NULL, err: File::NULL)
    with_project(FILES) do |root|
      git = ->(*a) { Open3.capture3('git', '-C', root, *a).last.success? || flunk("git #{a.join(' ')}") }
      git.call('init', '-q')
      git.call('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'add', '.')
      git.call('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-q', '-m', 'init')
      assert_empty sel(root, since: 'HEAD').files
      File.write(File.join(root, 'lib/a.rb'), "def f(x)\n  x + 2\nend\n")
      File.write(File.join(root, 'lib/new.rb'), "1\n")
      assert_equal ['lib/a.rb', 'lib/new.rb'], sel(root, since: 'HEAD').files
      assert_raises(Mutaruby::Error) { sel(root, since: 'no-such-ref').files }
    end
  end
end
