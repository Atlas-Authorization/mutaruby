# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'rexml/document'

class ReportersTest < Minitest::Test
  include TestHelpers

  SRC = "def f(a)\n  a < 1 && a > -b\nend\n"

  def report
    ms = Mutaruby::Generator.new(SRC, path: 'lib/f.rb', operators: Set['comparison', 'logical-swap', 'unary-minus-removal']).mutations
    assert_equal 4, ms.size
    entry = Mutaruby::IgnoreFile.new([{ 'file' => 'lib/f.rb', 'operator' => 'unary-minus-removal', 'line' => 'a < 1 && a > -b',
                                        'reason' => 'r & <why>' }]).entries.first
    outcomes = [[:killed, nil], [:survived, nil], [:timeout, nil], [:equivalent, entry]].each_with_index.map do |(st, ig), i|
      Mutaruby::Runner::Outcome.new(mutation: ms[i], status: st, seconds: 0.25, ignore: ig)
    end
    Mutaruby::Runner::Report.new(root: '/r', command: 'rake', files: ['lib/f.rb'], outcomes: outcomes,
                                 sources: { 'lib/f.rb' => SRC }, stale: [entry], warnings: ['w1'], baseline_seconds: 1.5,
                                 timeout: 10, jobs: 2, seconds: 3.25, complete: true)
  end

  def test_score_counts
    r = report
    assert_equal 2, r.killed
    assert_in_delta 66.6667, r.score, 0.001
    assert_equal '66.67%', Mutaruby::Reporters.score_text(r)
  end

  def test_human
    io = StringIO.new
    Mutaruby::Reporters.human(report, io, verbose: true)
    s = io.string
    assert_match(/Surviving mutants/, s)
    assert_match(%r{lib/f\.rb:2 in f  \[#1\]}, s)
    assert_match(/^    - {3}a < 1 && a > -b$/, s)
    assert_match(/killed:      2 \(1 by timeout\)/, s)
    assert_match(/survived:    1/, s)
    assert_match(/equivalent:  1/, s)
    assert_match(/score:       66\.67%/, s)
    assert_match(/time:        3\.2s \(baseline 1\.50s, timeout 10s, jobs 2\)/, s)
    assert_match(/timeout: lib\/f\.rb:2/, s)
    assert_match(/equivalent: lib\/f\.rb:2 .*\(r & <why>\)/, s)
    assert_match(/STALE ignore entry/, s)
    assert_match(/warning: w1/, s)
    quiet = StringIO.new
    Mutaruby::Reporters.human(report, quiet)
    refute_match(/timeout: lib/, quiet.string)
  end

  def test_json
    io = StringIO.new
    Mutaruby::Reporters.json(report, io)
    j = JSON.parse(io.string)
    assert_equal 'mutaruby', j['tool']
    assert_equal Mutaruby::VERSION, j['version']
    assert_in_delta 66.6667, j['score'], 0.001
    assert_equal({ 'mutants' => 4, 'killed' => 2, 'timeout' => 1, 'survived' => 1, 'equivalent' => 1 }, j['counts'])
    assert_equal %w[killed survived timeout equivalent], j['mutants'].map { |m| m['status'] }
    m = j['mutants'][1]
    assert_equal ['lib/f.rb', 2, 'f', 'a < 1 && a > -b', 1], m.values_at('file', 'lineno', 'method', 'line_text', 'occurrence')
    assert_equal 'r & <why>', j['mutants'][3]['ignore_reason']
    assert_equal 'unary-minus-removal', j['stale_ignores'][0]['operator']
    refute j['stale_ignores'][0].key?('index')
    assert_equal ['w1'], j['warnings']
    assert_equal 'rake', j['command']
    assert j['complete']
  end

  def test_junit
    io = StringIO.new
    Mutaruby::Reporters.junit(report, io)
    doc = REXML::Document.new(io.string)
    suite = doc.elements['testsuites/testsuite']
    assert_equal %w[4 1 1], %w[tests failures skipped].map { |a| suite.attributes[a] }
    cases = suite.get_elements('testcase')
    assert_equal 4, cases.size
    assert_nil cases[0].elements['failure']
    assert_equal 'survived', cases[1].elements['failure'].attributes['type']
    assert_equal "-   a < 1 && a > -b\n+   a <= 1 && a > -b", cases[1].elements['failure'].text
    assert_equal 'killed by timeout', cases[2].elements['system-out'].text
    assert_equal 'equivalent: r & <why>', cases[3].elements['skipped'].attributes['message']
    assert_equal '66.67%', suite.elements['properties/property'].attributes['value']
    assert_equal 'lib/f.rb', cases[0].attributes['classname']
  end
end
