# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mutaruby'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'

module TestHelpers
  # Mutants of a snippet as [operator, orig, repl] triples.
  def muts(src, operators: nil)
    Mutaruby::Generator.new(src, path: 'snippet.rb', operators: operators&.to_set).mutations
  end

  def triples(src, operators: nil)
    muts(src, operators: operators).map { |m| [m.operator, m.orig, m.repl] }
  end

  def changes(src, op)
    muts(src, operators: [op]).map(&:change)
  end

  # Builds a throwaway project: { "lib/a.rb" => "..." }. Yields the root and removes it afterwards.
  def with_project(files)
    Dir.mktmpdir('mrtest-') do |dir|
      root = File.join(dir, 'proj')
      files.each do |rel, body|
        path = File.join(root, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield root
    end
  end

  # Sets (or, with nil, removes) environment variables for the block and restores them afterwards.
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def options(**kw)
    Mutaruby::Runner::Options.build(jobs: 2, **kw)
  end

  def snapshot(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.reject { |f| File.directory?(File.join(root, f)) }
       .to_h { |f| [f, File.binread(File.join(root, f))] }
  end
end
