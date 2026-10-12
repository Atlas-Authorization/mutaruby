# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'

class SelectionTest < Minitest::Test
  include TestHelpers

  S = Mutaruby::Selection
  FILES = { 'lib/a.rb' => "def f(x)\n  x + 1\nend\n", 'lib/sub/b.rb' => "class K\n  def g(y) = y * 2\nend\nZ = 3\n",
            'app/c.rb' => "1\n" }.freeze

  def sel(root = '.', lines: [], exclude_lines: [], **kw)
    S.new(root: root, lines: lines.map { |l| S.parse_line_spec(l) },
          exclude_lines: exclude_lines.map { |l| S.parse_line_spec(l) }, **kw)
  end

  def mutations
    ms = FILES.first(2).flat_map { |f, src| Mutaruby::Generator.new(src, path: f).mutations }
    ms.each_with_index { |m, i| m.id = i }
  end

  def ids(list) = list.map(&:id)

  def test_default_patterns
    assert_equal ['lib/**/*.rb'], S::DEFAULT_PATTERNS
    with_project(FILES) { |root| assert_equal ['lib/a.rb', 'lib/sub/b.rb'], sel(root).files }
  end

  def test_explicit_patterns_are_relative_to_the_root_sorted_and_unique
    with_project(FILES.merge('lib/dir.rb/x' => '')) do |root|
      assert_equal ['app/c.rb', 'lib/a.rb'], sel(root, patterns: ['lib/a.rb', './app/*.rb', 'lib/*.rb']).files
      assert_equal ['lib/sub/b.rb'], sel(root, patterns: [File.join(root, 'lib/sub/b.rb')]).files
      assert_equal ['lib/a.rb'], sel(root, patterns: ['lib/*']).files, 'directories are not files'
      assert_empty sel(root, patterns: ['nothing/**/*.rb']).files
      Dir.chdir(root) { assert_equal ['lib/a.rb'], sel('.', patterns: ['lib/a.rb']).files }
    end
  end

  def test_files_outside_the_root_are_refused
    with_project(FILES) do |root|
      err = assert_raises(Mutaruby::Error) { sel(File.join(root, 'lib'), patterns: ['../app/c.rb']).files }
      assert_equal "../app/c.rb is outside the project root #{File.join(root, 'lib')}", err.message
    end
  end

  def test_line_specs
    s = S.parse_line_spec('lib/a.rb:2-4')
    assert_equal ['lib/a.rb', 2, 4], [s.file, s.from, s.to]
    s = S.parse_line_spec('./lib/a.rb:7')
    assert_equal ['lib/a.rb', 7, 7], [s.file, s.from, s.to]
    s = S.parse_line_spec('3-5')
    assert_equal [nil, 3, 5], [s.file, s.from, s.to]
    s = S.parse_line_spec('c:/x.rb:12')
    assert_equal ['c:/x.rb', 12, 12], [s.file, s.from, s.to]
    err = assert_raises(Mutaruby::Error) { S.parse_line_spec('x') }
    assert_equal 'bad line spec "x" (expected [FILE:]LINE or [FILE:]FROM-TO)', err.message
    err = assert_raises(Mutaruby::Error) { S.parse_line_spec('5-3') }
    assert_equal 'bad line spec "5-3" (FROM > TO)', err.message
    assert_raises(Mutaruby::Error) { S.parse_line_spec('1-2x') }
    assert_raises(Mutaruby::Error) { S.parse_line_spec('x1') }
  end

  def test_line_spec_cover
    m = Struct.new(:file, :lineno)
    s = S.parse_line_spec('a.rb:3-5')
    assert_equal [false, true, true, true, false], [2, 3, 4, 5, 6].map { |l| s.cover?(m.new('a.rb', l)) }
    refute s.cover?(m.new('b.rb', 4))
    assert S.parse_line_spec('4').cover?(m.new('b.rb', 4))
    refute S.parse_line_spec('4').cover?(m.new('b.rb', 5))
  end

  def test_shard_spec
    assert_equal [2, 3], S.parse_shard('2/3')
    assert_equal [1, 1], S.parse_shard('1/1')
    assert_equal [3, 3], S.parse_shard('3/3')
    %w[0/3 4/3 1/0 0/0 a/b 3 /3 2/ 1/2/3].each do |bad|
      err = assert_raises(Mutaruby::Error, bad) { S.parse_shard(bad) }
      assert_equal "bad --shard #{bad.inspect} (expected I/N, 1 <= I <= N)", err.message
    end
  end

  def test_shards_partition_the_mutants_round_robin
    ms = mutations
    assert_operator ms.size, :>=, 9
    parts = (1..3).map { |i| ids(sel(shard: [i, 3]).filter(ms)) }
    assert_equal ids(ms).select { |i| (i % 3).zero? }, parts[0]
    assert_equal ids(ms).select { |i| i % 3 == 1 }, parts[1]
    assert_equal ids(ms).select { |i| i % 3 == 2 }, parts[2]
    assert_equal ids(ms), ids(sel(shard: [1, 1]).filter(ms))
    # sharding applies after the other filters
    in_g = ids(sel(methods: ['g']).filter(ms))
    assert_equal in_g.each_slice(2).map(&:first), ids(sel(methods: ['g'], shard: [1, 2]).filter(ms))
  end

  def test_complete_only_without_filters
    assert sel.complete?
    refute sel(methods: ['f']).complete?
    refute sel(exclude_methods: ['f']).complete?
    refute sel(lines: ['1']).complete?
    refute sel(exclude_lines: ['1']).complete?
    refute sel(shard: [1, 2]).complete?
  end

  def test_method_filters
    ms = mutations
    f = ids(ms.select { |m| m.method == 'f' })
    g = ids(ms.select { |m| m.method == 'K#g' })
    top = ids(ms.select { |m| m.method.nil? })
    refute_empty f
    refute_empty g
    refute_empty top
    assert_equal ids(ms), ids(sel.filter(ms))
    assert_equal f, ids(sel(methods: ['f']).filter(ms))
    assert_equal g, ids(sel(methods: ['K#g']).filter(ms))
    assert_equal g, ids(sel(methods: ['K#*']).filter(ms))
    assert_equal g, ids(sel(methods: ['g']).filter(ms))
    assert_equal [], ids(sel(methods: ['K.g']).filter(ms))
    assert_equal (f + g).sort, ids(sel(methods: ['*']).filter(ms))
    assert_equal (f + g).sort, ids(sel(methods: %w[f g]).filter(ms))
    assert_equal (g + top).sort, ids(sel(exclude_methods: ['f']).filter(ms))
    assert_equal top, ids(sel(exclude_methods: ['*']).filter(ms))
    assert_equal f, ids(sel(methods: ['*'], exclude_methods: ['K#g']).filter(ms))
  end

  def test_line_filters
    ms = mutations
    on2 = ids(ms.select { |m| m.lineno == 2 })
    a2 = ids(ms.select { |m| m.lineno == 2 && m.file == 'lib/a.rb' })
    b4 = ids(ms.select { |m| m.lineno == 4 && m.file == 'lib/sub/b.rb' })
    refute_empty a2
    refute_equal a2, on2
    assert_equal a2, ids(sel(lines: ['lib/a.rb:2']).filter(ms))
    assert_equal on2, ids(sel(lines: ['2']).filter(ms))
    assert_equal (a2 + b4).sort, ids(sel(lines: ['lib/a.rb:2', 'lib/sub/b.rb:4']).filter(ms))
    assert_equal ids(ms) - on2, ids(sel(exclude_lines: ['2-2']).filter(ms))
    assert_equal ids(ms) - a2, ids(sel(exclude_lines: ['lib/a.rb:2']).filter(ms))
    assert_equal ids(ms), ids(sel(exclude_lines: ['lib/zzz.rb:1-99']).filter(ms))
    assert_equal on2 - a2, ids(sel(lines: ['2'], exclude_lines: ['lib/a.rb:1-9']).filter(ms))
  end

  def git(root, *args)
    _, err, st = Open3.capture3('git', '-C', root, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', *args)
    assert st.success?, err
  end

  # --since works from a subdirectory of the repository, with a ref that is also a path, and skips ignored files.
  def test_since_uses_git_diff_and_untracked_files
    with_project(FILES.transform_keys { |k| "sub/#{k}" }.merge('.gitignore' => "gen.rb\n")) do |repo|
      git(repo, 'init', '-q')
      git(repo, 'add', '.')
      git(repo, 'commit', '-q', '-m', 'init')
      git(repo, 'branch', 'lib')
      root = File.join(repo, 'sub')
      assert_empty sel(root, since: 'HEAD').files
      File.write(File.join(root, 'lib/a.rb'), "def f(x)\n  x + 2\nend\n")
      File.write(File.join(root, 'lib/new.rb'), "1\n")
      File.write(File.join(root, 'lib/gen.rb'), "1\n")
      assert_equal ['lib/a.rb', 'lib/new.rb'], sel(root, since: 'HEAD').files
      assert_equal ['lib/a.rb', 'lib/new.rb'], sel(root, since: 'lib').files
      err = assert_raises(Mutaruby::Error) { sel(root, since: 'no-such-ref').files }
      assert_match(/\Agit diff --name-only --relative no-such-ref -- failed: \S.*\S\z/m, err.message)
    end
  end
end
