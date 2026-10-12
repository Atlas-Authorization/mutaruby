# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'open3'
require 'rbconfig'

# Runs the real CLI against test/fixtures/calc, a small project with known killable, surviving, equivalent and
# timeout mutants, using its real minitest suite as the oracle.
class CalcE2ETest < Minitest::Test
  include TestHelpers

  ROOT = File.expand_path('../fixtures/calc', __dir__)
  EXE = File.expand_path('../../exe/mutaruby', __dir__)

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, EXE, '-C', ROOT, '-t', %("#{RbConfig.ruby}" test/test_calc.rb), '-q', *args)
  end

  def by(report, operator, line, change = nil)
    found = report['mutants'].select do |m|
      m['operator'] == operator && m['line_text'] == line && (change.nil? || m['change'] == change)
    end
    refute_empty found, "no #{operator} mutant on #{line.inspect}"
    found.map { |m| m['status'] }.uniq
  end

  def test_full_run
    before = snapshot(ROOT)
    Dir.mktmpdir do |d|
      json = File.join(d, 'r.json')
      xml = File.join(d, 'r.xml')
      out, err, st = run_cli('-j', '4', '--timeout', '5', '--json', json, '--junit', xml, '--fail-under', '80')
      assert st.success?, "exit #{st.exitstatus}\n#{out}\n#{err}"
      r = JSON.parse(File.read(json))

      # killable
      assert_equal ['killed'], by(r, 'arithmetic', 'a + b')
      assert_equal ['killed'], by(r, 'comparison', 'n > 0')
      assert_equal ['killed'], by(r, 'method-body-bool', 'n > 0')
      # deleting the require is only visible in a fresh process (the test file does not load the helper itself)
      assert_equal ['killed'], by(r, 'statement-delete', "require_relative 'calc/helper'")
      # the multi-byte string sits before most of the code; its mutants and every later one are placed correctly
      assert_equal ['survived'], by(r, 'literal-string', "GREETING = 'naïve'")
      assert_equal ['survived'], by(r, 'statement-delete', "GREETING = 'naïve'")
      # equivalent, listed in the fixture's .mutaruby-ignore.yml
      assert_equal ['equivalent'], by(r, 'comparison', 'return 0 if n < 0', '< => <=')
      # infinite loops
      assert_equal ['timeout'], by(r, 'op-assign', 'i += 1 while i < n')
      assert_equal ['timeout'], by(r, 'literal-int', 'i += 1 while i < n', '1 => 0')

      c = r['counts']
      assert_equal 2, c['survived'], out
      assert_equal 1, c['equivalent']
      assert_equal 2, c['timeout']
      assert_equal c['mutants'] - 3, c['killed']
      assert_in_delta 100.0 * c['killed'] / (c['mutants'] - 1), r['score'], 0.01
      assert_empty r['stale_ignores']
      assert_match(/Surviving mutants/, out)
      assert_match(/failures="2"/, File.read(xml))
    end
    assert_equal before, snapshot(ROOT), 'the fixture project was modified'
  end

  def test_fail_under_and_filters
    _, err, st = run_cli('--fail-under', '99', '--method', 'Calc#add', '-j', '2')
    assert_equal 0, st.exitstatus, err # Calc#add: every mutant killed
    _, err, st = run_cli('--fail-under', '99', '--line', 'lib/calc.rb:8', '-j', '2')
    assert_equal 1, st.exitstatus
    assert_match(/below --fail-under/, err)
  end
end
