# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

class ReportersTest < Minitest::Test
  include TestHelpers

  R = Mutaruby::Reporters
  GOLDEN = File.expand_path('../golden', __dir__)
  SRC_A = "class A\n  def f(a)\n    a < 1 && a > -b\n  end\nend\n"
  SRC_B = "X = 1 + 2 - 3 * 4\n"

  def report(stale: true, coverage: 'minitest')
    ma = Mutaruby::Generator.new(SRC_A, path: 'lib/a.rb', operators: %w[comparison logical-swap unary-minus-removal]).mutations
    mb = Mutaruby::Generator.new(SRC_B, path: 'lib/b&c.rb', operators: %w[arithmetic]).mutations
    ms = ma + mb
    ms.each_with_index { |m, i| m.id = i }
    ign = Mutaruby::IgnoreFile.new([{ 'file' => 'lib/a.rb', 'operator' => 'unary-minus-removal', 'line' => 'a < 1 && a > -b',
                                      'reason' => 'r & <why>' },
                                    { 'file' => 'lib/a.rb', 'operator' => 'comparison', 'line' => 'a < 1 && a > -b',
                                      'lineno' => 3, 'method' => 'A#f', 'reason' => 'gone' }]).entries
    statuses = [[:killed, nil], [:survived, nil], [:timeout, nil], [:equivalent, ign[0]], [:survived, nil], [:killed, nil],
                [:killed, nil]]
    outcomes = statuses.each_with_index.map do |(st, ig), i|
      Mutaruby::Runner::Outcome.new(mutation: ms[i], status: st, seconds: 0.123456 * (i + 1), ignore: ig,
                                    tests: i.odd? ? i : nil)
    end
    Mutaruby::Runner::Report.new(root: '/r', command: 'rake test', files: ['lib/a.rb', 'lib/b&c.rb'], outcomes: outcomes,
                                 sources: { 'lib/a.rb' => SRC_A, 'lib/b&c.rb' => SRC_B }, stale: stale ? [ign[1]] : [],
                                 warnings: ['w1'], baseline_seconds: 1.234567, timeout: 9, jobs: 2, seconds: 3.256789,
                                 complete: true, coverage: coverage)
  end

  def golden(name) = File.read(File.join(GOLDEN, name))

  def test_score_text
    assert_equal '66.67%', R.score_text(report)
    assert_equal 'n/a', R.score_text(Mutaruby::Runner::Report.new(outcomes: []))
    r = Mutaruby::Runner::Report.new(outcomes: [Mutaruby::Runner::Outcome.new(status: :killed)] * 2 +
                                               [Mutaruby::Runner::Outcome.new(status: :survived)])
    assert_equal '66.67%', R.score_text(r)
  end

  def test_human
    io = StringIO.new
    R.human(report, io)
    assert_equal golden('human.txt'), io.string
  end

  def test_human_verbose
    io = StringIO.new
    R.human(report, io, verbose: true)
    assert_equal golden('human-verbose.txt'), io.string
  end

  def test_human_without_coverage
    io = StringIO.new
    R.human(report(coverage: nil), io)
    refute_includes io.string, 'coverage:'
    assert_includes golden('human.txt'), "  coverage:    minitest: 3 of 7 mutants ran only the tests covering them\n"
  end

  def test_human_without_survivors
    r = report(stale: false)
    r.outcomes = r.outcomes.reject { |o| o.status == :survived }
    r.warnings = []
    io = StringIO.new
    R.human(r, io)
    assert io.string.start_with?("mutaruby summary\n"), io.string
  end

  def test_json
    io = StringIO.new
    R.json(report, io)
    assert_equal golden('report.json').sub('VERSION', Mutaruby::VERSION), io.string
  end

  def test_json_without_score
    r = Mutaruby::Runner::Report.new(outcomes: [], stale: [], warnings: [], files: [], baseline_seconds: 0.5, timeout: 6,
                                     command: 'x', complete: false)
    assert_nil R.json_data(r)[:score]
  end

  def test_junit
    io = StringIO.new
    R.junit(report, io)
    assert_equal golden('report.xml'), io.string
  end
end
