# frozen_string_literal: true

require_relative '../test_helper'

class IgnoreFileTest < Minitest::Test
  include TestHelpers

  I = Mutaruby::IgnoreFile
  SRC = "def a(n)\n  return 0 if n < 0\n  n\nend\ndef b(n)\n  return 0 if n < 0\n  n\nend\n"

  def entry(**kw)
    { 'file' => 'lib/x.rb', 'operator' => 'comparison', 'line' => 'return 0 if n < 0', 'reason' => 'equivalent' }
      .merge(kw.transform_keys(&:to_s))
  end

  def mutants
    Mutaruby::Generator.new(SRC, path: 'lib/x.rb', rel: 'lib/x.rb', operators: ['comparison']).mutations
  end

  def invalid(data, path: '(ignore file)')
    assert_raises(I::Invalid) { I.new(data, path: path) }.message
  end

  def test_constants
    assert_equal %w[file operator line occurrence method mutation lineno reason], I::KEYS
    assert_equal %w[file operator line reason], I::REQUIRED
    assert_equal %w[file operator reason method mutation], I::STRINGS
  end

  def test_required_keys
    assert_equal '(ignore file): entry #1: `reason` is required', invalid([entry(reason: ' ')])
    assert_equal '(ignore file): entry #2: `reason` is required', invalid([entry, entry(reason: nil)])
    %w[file operator line].each do |k|
      assert_equal "(ignore file): entry #1: `#{k}` is required", invalid([entry.except(k)])
    end
  end

  def test_rejects_bad_shapes
    assert_equal 'f.yml: expected a list of entries', invalid('x', path: 'f.yml')
    assert_equal '(ignore file): expected a list of entries', assert_raises(I::Invalid) { I.new('x') }.message
    assert_equal '(ignore file): expected a list of entries', invalid({ 'x' => [entry] })
    assert_equal '(ignore file): entry #1: expected a mapping', invalid(['x'])
    assert_equal '(ignore file): entry #1: unknown key(s) colour, size', invalid([entry(colour: 'red', size: 1)])
    assert_equal '(ignore file): entry #1: unknown operator "nope"', invalid([entry(operator: 'nope')])
    assert_equal '(ignore file): entry #1: `occurrence` must be a positive integer', invalid([entry(occurrence: 0)])
    assert_equal '(ignore file): entry #1: `occurrence` must be a positive integer', invalid([entry(occurrence: '2')])
    assert_equal '(ignore file): entry #1: `lineno` must be a positive integer', invalid([entry(lineno: -3)])
    assert_equal '(ignore file): entry #1: `reason` must be a string', invalid([entry(reason: 5)])
    assert_equal '(ignore file): entry #1: `method` must be a string', invalid([entry(method: 5)])
    assert_equal '(ignore file): entry #1: `file` must be a string', invalid([entry(file: 5)])
    assert_equal '(ignore file): entry #1: `mutation` must be a string', invalid([entry(mutation: [1])])
    assert_equal [], I.new(nil).entries
    assert_equal [], I.new({ 'ignore' => nil }).entries
    assert_equal 1, I.new({ 'ignore' => [entry] }).entries.size
  end

  # A Ruby line such as `42` or `true` reads as a number or a boolean in YAML; it is taken as text.
  def test_non_string_line_values
    e = I.new([entry(line: 42), entry(line: true)]).entries
    assert_equal %w[42 true], e.map(&:line)
  end

  def test_entry_fields_are_normalised
    e = I.new([entry(file: './lib/x.rb', line: '  return 0 if n < 0  ', reason: '  why  ', mutation: "  <   =>\t<=  ",
                     method: 'a', occurrence: 2, lineno: 9)]).entries.first
    assert_equal ['lib/x.rb', 'comparison', 'return 0 if n < 0', 2, 'a', '< => <=', 9, 'why', 0],
                 [e.file, e.operator, e.line, e.occurrence, e.method, e.mutation, e.lineno, e.reason, e.index]
    assert_nil I.new([entry]).entries.first.mutation
  end

  def test_labels
    e = I.new([entry, entry(lineno: 7, occurrence: 2, method: 'Calc#f')]).entries
    assert_equal '#1 lib/x.rb comparison "return 0 if n < 0"', e[0].label
    assert_equal '#2 lib/x.rb:7 comparison "return 0 if n < 0" (occurrence 2) in Calc#f', e[1].label
  end

  def test_load_from_yaml
    Dir.mktmpdir do |d|
      p = File.join(d, 'i.yml')
      File.write(p, "- file: lib/x.rb\n  operator: comparison\n  line: 'return 0 if n < 0'\n  occurrence: 2\n  reason: r\n")
      f = I.load(p)
      assert_equal [['lib/x.rb', 2, 'r']], f.entries.map { |e| [e.file, e.occurrence, e.reason] }
      assert_equal p, f.path
      File.binwrite(p, "- file: a\n  operator: comparison\n  line: x\n  reason: caf\xC3\xA9\n")
      verbose = $VERBOSE
      old = Encoding.default_external
      $VERBOSE = nil
      Encoding.default_external = Encoding::ISO_8859_1
      begin
        assert_equal "caf\u00e9", I.load(p).entries.first.reason
      ensure
        Encoding.default_external = old
        $VERBOSE = verbose
      end
      File.write(p, "- [unclosed\n")
      err = assert_raises(I::Invalid) { I.load(p) }
      assert_match(/\A#{Regexp.escape(p)}: not valid YAML \(.*line 1 column 3\)\z/, err.message)
      File.write(p, "- &a {file: x}\n- *a\n")
      assert_raises(Psych::BadAlias) { I.load(p) }
      File.write(p, "- !ruby/object:Object {}\n")
      assert_raises(Psych::DisallowedClass) { I.load(p) }
    end
  end

  def test_validation_messages
    f = I.new([entry, entry(occurrence: 3), entry(line: 'gone'), entry(occurrence: 2), entry(file: 'other.rb')])
    assert_equal ['AMBIGUOUS (the line occurs 2 times; add `occurrence`): #1 lib/x.rb comparison "return 0 if n < 0"',
                  'STALE (occurrence 3 but the line now occurs 2 time(s)): #2 lib/x.rb comparison "return 0 if n < 0" ' \
                  '(occurrence 3)',
                  'STALE (the line is no longer in the file; re-review or remove the entry): #3 lib/x.rb comparison "gone"'],
                 f.validate('lib/x.rb' => SRC)
  end

  def test_unique_lines_need_no_occurrence
    assert_equal [], I.new([entry(line: 'def a(n)')]).validate('lib/x.rb' => SRC)
    assert_equal [], I.new([entry(line: 'def a(n)', occurrence: 1)]).validate('lib/x.rb' => SRC)
    assert_equal [], I.new([entry(occurrence: 2)]).validate('lib/x.rb' => SRC)
    assert_equal 1, I.count_lines(SRC, 'def a(n)')
    assert_equal 2, I.count_lines(SRC, 'n')
    assert_equal 0, I.count_lines(SRC, '')
  end

  def test_match_by_site
    a, b = mutants
    f = I.new([entry(occurrence: 2)])
    assert_nil f.match(a)
    assert_equal 0, f.match(b).index
    assert_equal 0, I.new([entry(occurrence: 1)]).match(a).index
    unique = Mutaruby::Generator.new("x if a > 1\ny\n", path: 'u.rb', operators: ['comparison']).mutations.first
    assert I.new([entry(file: 'u.rb', line: 'x if a > 1')]).match(unique), 'no occurrence means the first'
    assert_equal 1, I.new([entry(file: 'z.rb'), entry(occurrence: 1)]).match(a).index
  end

  def test_match_narrowed_by_method_and_mutation
    a, = mutants
    assert I.new([entry(occurrence: 1, method: 'a')]).match(a)
    assert_nil I.new([entry(occurrence: 1, method: 'b')]).match(a)
    assert I.new([entry(occurrence: 1, mutation: '  <   =>   <=')]).match(a)
    assert_nil I.new([entry(occurrence: 1, mutation: '< => >')]).match(a)
    assert_nil I.new([entry(occurrence: 1, operator: 'arithmetic')]).match(a)
    assert_nil I.new([entry(occurrence: 1, file: 'lib/y.rb')]).match(a)
    assert_nil I.new([entry(occurrence: 1, line: 'n')]).match(a)
  end

  def test_lineno_is_only_a_hint
    a, = mutants
    assert I.new([entry(occurrence: 1, lineno: 99)]).match(a)
  end

  def test_stale_after_run
    f = I.new([entry(occurrence: 1), entry(occurrence: 2), entry(file: 'z.rb')])
    assert_equal [1], f.stale([f.entries[0]], ['lib/x.rb']).map(&:index)
    assert_equal [1, 2], f.stale([f.entries[0]], ['lib/x.rb', 'z.rb']).map(&:index)
    assert_equal [], f.stale(f.entries, ['lib/x.rb', 'z.rb'])
  end

  def test_stub_for_survivors
    a, b = mutants
    assert_equal <<~YAML, I.stub_for([a, b], 'lib/x.rb' => SRC)
      ---
      - file: lib/x.rb
        operator: comparison
        line: return 0 if n < 0
        occurrence: 1
        method: a
        mutation: "< => <="
        lineno: 2
        reason: ''
      - file: lib/x.rb
        operator: comparison
        line: return 0 if n < 0
        occurrence: 2
        method: b
        mutation: "< => <="
        lineno: 6
        reason: ''
    YAML
    assert_raises(I::Invalid) { I.new(YAML.safe_load(I.stub_for([a], 'lib/x.rb' => SRC))) }
    src = "x if a > 1\ny\n"
    unique = Mutaruby::Generator.new(src, path: 'u.rb', operators: ['comparison']).mutations
    assert_equal <<~YAML, I.stub_for(unique, 'u.rb' => src)
      ---
      - file: u.rb
        operator: comparison
        line: x if a > 1
        mutation: "> => >="
        lineno: 1
        reason: ''
    YAML
  end

  # Every stub, once given a reason, matches the mutant it was made for (including changes with an empty replacement
  # and multi-line slices).
  def test_stubs_round_trip
    src = "def f(a, b)\n  g(a)\n  h(a,\n    b) if a > 1\n  return a + b\nend\ndef k = g(1)\n"
    ms = Mutaruby::Generator.new(src, path: 'r.rb').mutations
    assert_operator ms.size, :>, 15
    data = YAML.safe_load(I.stub_for(ms, 'r.rb' => src)).each { |h| h['reason'] = 'r' }
    f = I.new(data)
    assert_equal [], f.validate('r.rb' => src)
    ms.each { |m| assert f.match(m), m.label }
    assert_includes data.map { |h| h['mutation'] }, 'a =>'
  end
end
