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
          io.puts m.diff(report.sources[m.file]).gsub(/^/, '    ')
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
      if report.coverage
        subset = report.outcomes.count(&:tests)
        io.puts "  coverage:    #{report.coverage}: #{subset} of #{report.outcomes.size} mutants ran only the tests covering them"
      end
      io.puts format('  time:        %.1fs (baseline %.2fs, timeout %ss, jobs %d)', report.seconds,
                     report.baseline_seconds, report.timeout, report.jobs)
    end

    def json_data(report)
      {
        tool: 'mutaruby', version: VERSION, command: report.command,
        score: report.score&.round(4), complete: report.complete, coverage: report.coverage,
        counts: { mutants: report.outcomes.size, killed: report.killed, timeout: report.count(:timeout),
                  survived: report.count(:survived), equivalent: report.count(:equivalent) },
        files: report.files, baseline_seconds: secs(report.baseline_seconds), timeout: report.timeout,
        mutants: report.outcomes.map do |o|
          o.mutation.to_h.merge(status: o.status, seconds: secs(o.seconds), ignore_reason: o.ignore&.reason, tests: o.tests)
        end,
        stale_ignores: report.stale.map { |e| e.to_h.compact.except(:index) },
        warnings: report.warnings
      }
    end

    def json(report, io)
      io.puts JSON.pretty_generate(json_data(report))
    end

    # JUnit-style XML: one testcase per mutant. A survivor is a failure, an equivalent mutant is skipped.
    def junit(report, io)
      n = report.outcomes.size
      failures = report.count(:survived)
      t = secs(report.seconds)
      io.puts '<?xml version="1.0" encoding="UTF-8"?>'
      io.puts %(<testsuites name="mutaruby" tests="#{n}" failures="#{failures}" time="#{t}">)
      io.puts %(  <testsuite name="mutaruby" tests="#{n}" failures="#{failures}" errors="0" ) +
              %(skipped="#{report.count(:equivalent)}" time="#{t}">)
      io.puts %(    <properties><property name="score" value="#{score_text(report)}"/></properties>)
      report.outcomes.each do |o|
        m = o.mutation
        head = %(    <testcase classname="#{esc(m.file)}" name="#{esc("##{m.id} #{m.location} #{m.label}")}" ) +
               %(time="#{secs(o.seconds)}")
        detail = junit_detail(o, report)
        io.puts(detail ? "#{head}>\n      #{detail}\n    </testcase>" : "#{head}/>")
      end
      io.puts '  </testsuite>'
      io.puts '</testsuites>'
    end

    def junit_detail(outcome, report)
      m = outcome.mutation
      case outcome.status
      when :survived
        %(<failure message="#{esc("survived: #{m.label}")}" type="survived">#{esc(m.diff(report.sources[m.file]))}</failure>)
      when :equivalent then %(<skipped message="#{esc("equivalent: #{outcome.ignore.reason}")}"/>)
      when :timeout then '<system-out>killed by timeout</system-out>'
      end
    end

    def esc(text)
      CGI.escapeHTML(text)
    end

    def secs(seconds)
      seconds.round(3)
    end
  end
end
