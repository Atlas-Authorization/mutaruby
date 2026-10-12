# frozen_string_literal: true

require_relative '../test_helper'

class IgnoreFileTest < Minitest::Test
  include TestHelpers

  SRC = "def a(n)\n  return 0 if n < 0\n  n\nend\ndef b(n)\n  return 0 if n < 0\n  n\nend\n"

  def entry(**kw)
    { 'file' => 'lib/x.rb', 'operator' => 'comparison', 'line' => 'return 0 if n < 0', 'reason' => 'equivalent' }
      .merge(kw.transform_keys(&:to_s))
  end

  def mutants
    Mutaruby::Generator.new(SRC, path: 'lib/x.rb', rel: 'lib/x.rb', operators: Set['comparison']).mutations
  end

  def test_reason_is_required
    err = assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new([entry(reason: ' ')]) }
    assert_match(/`reason` is required/, err.message)
    %w[file operator line].each do |k|
      assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new([entry.except(k)]) }
    end
  end

  def test_rejects_bad_shapes
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new('x') }
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new(['x']) }
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new([entry(colour: 'red')]) }
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new([entry(operator: 'nope')]) }
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new([entry(occurrence: 0)]) }
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new([entry(lineno: '3')]) }
    assert_empty Mutaruby::IgnoreFile.new(nil).entries
    assert_equal 1, Mutaruby::IgnoreFile.new({ 'ignore' => [entry] }).entries.size
  end

  def test_load_from_yaml
    Dir.mktmpdir do |d|
      p = File.join(d, 'i.yml')
      File.write(p, "- file: ./lib/x.rb\n  operator: comparison\n  line: '  return 0 if n < 0  '\n  occurrence: 2\n  reason: r\n")
      f = Mutaruby::IgnoreFile.load(p)
      e = f.entries.first
      assert_equal ['lib/x.rb', 'return 0 if n < 0', 2, 'r', 0], [e.file, e.line, e.occurrence, e.reason, e.index]
      assert_equal p, f.path
      File.write(p, "- [unclosed\n")
      assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.load(p) }
    end
  end

  def test_ambiguous_and_stale_entries
    f = Mutaruby::IgnoreFile.new([entry, entry(occurrence: 3), entry(line: 'gone'), entry(occurrence: 2),
                                  entry(file: 'other.rb')])
    errs = f.validate('lib/x.rb' => SRC)
    assert_equal 3, errs.size
    assert_match(/AMBIGUOUS .*occurs 2 times/, errs[0])
    assert_match(/STALE \(occurrence 3/, errs[1])
    assert_match(/STALE \(the line is no longer/, errs[2])
  end

  def test_unique_line_needs_no_occurrence
    f = Mutaruby::IgnoreFile.new([entry(line: 'n', operator: 'comparison')])
    assert_match(/AMBIGUOUS/, f.validate('lib/x.rb' => SRC).first)
    assert_empty Mutaruby::IgnoreFile.new([entry(line: 'def a(n)')]).validate('lib/x.rb' => SRC)
  end

  def test_match_by_site
    a, b = mutants
    f = Mutaruby::IgnoreFile.new([entry(occurrence: 2)])
    assert_nil f.match(a)
    assert_equal 0, f.match(b).index
    assert_equal 0, Mutaruby::IgnoreFile.new([entry(occurrence: 1)]).match(a).index
  end

  def test_match_narrowed_by_method_and_mutation
    a, = mutants
    assert Mutaruby::IgnoreFile.new([entry(occurrence: 1, method: 'a')]).match(a)
    assert_nil Mutaruby::IgnoreFile.new([entry(occurrence: 1, method: 'b')]).match(a)
    assert Mutaruby::IgnoreFile.new([entry(occurrence: 1, mutation: '<   =>   <=')]).match(a)
    assert_nil Mutaruby::IgnoreFile.new([entry(occurrence: 1, mutation: '< => >')]).match(a)
    assert_nil Mutaruby::IgnoreFile.new([entry(occurrence: 1, operator: 'arithmetic')]).match(a)
    assert_nil Mutaruby::IgnoreFile.new([entry(occurrence: 1, file: 'lib/y.rb')]).match(a)
    assert_nil Mutaruby::IgnoreFile.new([entry(occurrence: 1, line: 'n')]).match(a)
  end

  def test_lineno_is_only_a_hint
    a, = mutants
    assert Mutaruby::IgnoreFile.new([entry(occurrence: 1, lineno: 99)]).match(a)
  end

  def test_stale_after_run
    f = Mutaruby::IgnoreFile.new([entry(occurrence: 1), entry(occurrence: 2), entry(file: 'z.rb')])
    stale = f.stale([f.entries[0]].to_set, ['lib/x.rb'])
    assert_equal [1], stale.map(&:index)
    assert_match(/#2 lib\/x.rb comparison "return 0 if n < 0" \(occurrence 2\)/, stale.first.label)
  end

  def test_stub_for_survivors
    a, b = mutants
    yaml = Mutaruby::IgnoreFile.stub_for([a, b], 'lib/x.rb' => SRC)
    data = YAML.safe_load(yaml)
    assert_equal [1, 2], data.map { |h| h['occurrence'] }
    assert_equal ['', ''], data.map { |h| h['reason'] }
    assert_equal '< => <=', data.first['mutation']
    assert_equal 2, data.first['lineno']
    assert_equal 'a', data.first['method']
    assert_raises(Mutaruby::IgnoreFile::Invalid) { Mutaruby::IgnoreFile.new(data) }
    unique = Mutaruby::Generator.new("x if a > 1\n", path: 'u.rb', operators: Set['comparison']).mutations
    refute YAML.safe_load(Mutaruby::IgnoreFile.stub_for(unique, 'u.rb' => "x if a > 1\n")).first.key?('occurrence')
  end
end
