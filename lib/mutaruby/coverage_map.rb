# frozen_string_literal: true

require 'json'

module Mutaruby
  # Which tests execute which lines of the project, recorded in the baseline run by the probe
  # (lib/mutaruby/probe/mutaruby_probe.rb) through Ruby's Coverage API. Used to run, for each mutant, only the tests
  # that reach its lines.
  class CoverageMap
    PROBE_DIR = File.expand_path('probe', __dir__).freeze

    # Environment that loads the probe into the test process, plus `extra` (the probe's own variables). RUBYLIB is a
    # path list (spaces are fine there); RUBYOPT names only the feature, so no path has to survive its splitting.
    def self.probe_env(extra)
      lib = [PROBE_DIR, ENV.fetch('RUBYLIB', '')].reject(&:empty?).join(File::PATH_SEPARATOR)
      opt = [ENV.fetch('RUBYOPT', ''), '-rmutaruby_probe'].reject(&:empty?).join(' ')
      { 'RUBYLIB' => lib, 'RUBYOPT' => opt }.merge(extra)
    end

    def self.load(path)
      new(JSON.parse(File.read(path, encoding: 'UTF-8')))
    end

    attr_reader :framework

    # data: { "framework" => "minitest" | "rspec" | nil, "tests" => { id => { file => [line, ...] } },
    #         "load" => { file => [line, ...] } }
    def initialize(data)
      @framework = data['framework']
      @tests = Hash.new { |h, k| h[k] = [] }
      data['tests'].each do |id, files|
        files.each { |file, lines| lines.each { |l| @tests[[file, l]] << id } }
      end
      @load = data['load'].flat_map { |file, lines| lines.map { |l| [file, l] } }
    end

    # True when the run recorded tests of a supported framework.
    def usable?
      !@framework.nil? && @tests.any?
    end

    # The ids of the tests that execute any of `lines` of `file`, sorted; nil when the whole suite has to run: a line
    # that ran while the code was loaded (a class body, a method definition), or a line no test reaches.
    def tests_for(file, lines)
      return nil if lines.any? { |l| @load.include?([file, l]) }

      ids = lines.flat_map { |l| @tests.fetch([file, l], []) }.uniq.sort
      ids.empty? ? nil : ids
    end
  end
end
