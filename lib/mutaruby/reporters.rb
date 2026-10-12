# frozen_string_literal: true

require 'json'
require 'cgi'
require_relative 'version'

module Mutaruby
  module Reporters
    module_function

    def score_text(report)
      s = report.score
      s.nil? ? 'n/a' : format('%.2f%%', s)
    end

    def human(report, io, verbose: false)
      survivors = report.outcomes.select { |o| o.status == :survived }
      if survivors.any?
        io.puts 'Surviving mutants (not detected by the test command):'
        survivors.each do |o|
          m = o.mutation
          io.puts
          io.puts "  #{m.location}#{m.method ? " in #{m.method}" : ''}  [##{m.id}]"
          io.puts "    #{m.label}"
          m.diff(report.sources[m.file]).each_line { |l| io.puts "    #{l.chomp}" }
        end
        io.puts
      end
      if verbose
        report.outcomes.select { |o| o.status == :timeout }.each do |o|
          io.puts "  timeout: #{o.mutation.location} #{o.mutation.label}"
        end
        report.outcomes.select { |o| o.status == :equivalent }.each do |o|
          io.puts "  equivalent: #{o.mutation.location} #{o.mutation.label} (#{o.ignore.reason})"
        end
      end
      report.stale.each { |e| io.puts "warning: STALE ignore entry (no surviving mutant at this site; remove or re-review it): #{e.label}" }
      report.warnings.each { |w| io.puts "warning: #{w}" }
      io.puts 'mutaruby summary'
      io.puts "  files:       #{report.files.size}"
      io.puts "  mutants:     #{report.outcomes.size}"
      io.puts "  killed:      #{report.killed} (#{report.count(:timeout)} by timeout)"
      io.puts "  survived:    #{report.count(:survived)}"
      io.puts "  equivalent:  #{report.count(:equivalent)} (ignore file)"
      io.puts "  score:       #{score_text(report)}  = killed / (mutants - equivalent)"
      io.puts format('  time:        %.1fs (baseline %.2fs, timeout %ss, jobs %d)', report.seconds,
                     report.baseline_seconds, report.timeout, report.jobs)
    end

    def json_data(report)
      {
        tool: 'mutaruby', version: VERSION, command: report.command,
        score: report.score&.round(4), complete: report.complete,
        counts: { mutants: report.outcomes.size, killed: report.killed, timeout: report.count(:timeout),
                  survived: report.count(:survived), equivalent: report.count(:equivalent) },
        files: report.files, baseline_seconds: report.baseline_seconds.round(3), timeout: report.timeout,
        mutants: report.outcomes.map do |o|
          o.mutation.to_h.merge(status: o.status.to_s, seconds: o.seconds.round(3), ignore_reason: o.ignore&.reason)
        end,
        stale_ignores: report.stale.map(&:to_h).map { |h| h.compact.except(:index) },
        warnings: report.warnings
      }
    end

    def json(report, io)
      io.puts JSON.pretty_generate(json_data(report))
    end

    # JUnit-style XML: one testcase per mutant. A survivor is a failure, an equivalent mutant is skipped.
    def junit(report, io)
      x = ->(s) { CGI.escapeHTML(s.to_s) }
      failures = report.count(:survived)
      io.puts '<?xml version="1.0" encoding="UTF-8"?>'
      io.puts %(<testsuites name="mutaruby" tests="#{report.outcomes.size}" failures="#{failures}" time="#{report.seconds.round(3)}">)
      io.puts %(  <testsuite name="mutaruby" tests="#{report.outcomes.size}" failures="#{failures}" errors="0" ) +
              %(skipped="#{report.count(:equivalent)}" time="#{report.seconds.round(3)}">)
      io.puts %(    <properties><property name="score" value="#{x.call(score_text(report))}"/></properties>)
      report.outcomes.each do |o|
        m = o.mutation
        name = "##{m.id} #{m.location} #{m.label}"
        io.print %(    <testcase classname="#{x.call(m.file)}" name="#{x.call(name)}" time="#{o.seconds.round(3)}")
        case o.status
        when :survived
          io.puts '>'
          io.puts %(      <failure message="#{x.call("survived: #{m.label}")}" type="survived">#{x.call(m.diff(report.sources[m.file]))}</failure>)
          io.puts '    </testcase>'
        when :equivalent
          io.puts '>'
          io.puts %(      <skipped message="#{x.call("equivalent: #{o.ignore.reason}")}"/>)
          io.puts '    </testcase>'
        when :timeout
          io.puts '>'
          io.puts '      <system-out>killed by timeout</system-out>'
          io.puts '    </testcase>'
        else
          io.puts '/>'
        end
      end
      io.puts '  </testsuite>'
      io.puts '</testsuites>'
    end
  end
end
