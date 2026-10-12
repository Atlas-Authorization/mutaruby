# frozen_string_literal: true

require_relative '../test_helper'

class SandboxTest < Minitest::Test
  include TestHelpers

  def test_copies_the_project_outside_the_root
    with_project('lib/a.rb' => 'A', '.git/HEAD' => 'x', 'coverage/i.html' => 'c', 'tmp/big' => 'b', '.rspec' => 'r') do |root|
      File.symlink('lib/a.rb', File.join(root, 'link.rb'))
      box = Mutaruby::Sandbox.new(root, excludes: ['tmp'])
      begin
        refute box.dir.start_with?(root)
        assert_equal 'proj', File.basename(box.dir)
        assert_equal 'A', File.read(box.path('lib/a.rb'))
        assert_equal 'r', File.read(box.path('.rspec'))
        assert File.symlink?(box.path('link.rb'))
        refute File.exist?(box.path('.git'))
        refute File.exist?(box.path('coverage'))
        refute File.exist?(box.path('tmp'))
      ensure
        box.cleanup
      end
      refute File.exist?(box.dir)
    end
  end

  def test_with_file_restores_the_original_even_on_error
    with_project('lib/a.rb' => 'orig') do |root|
      box = Mutaruby::Sandbox.new(root)
      seen = box.with_file('lib/a.rb', 'mutant', 'orig') { File.read(box.path('lib/a.rb')) }
      assert_equal 'mutant', seen
      assert_equal 'orig', File.read(box.path('lib/a.rb'))
      assert_raises(RuntimeError) { box.with_file('lib/a.rb', 'mutant', 'orig') { raise 'boom' } }
      assert_equal 'orig', File.read(box.path('lib/a.rb'))
      assert_equal 'orig', File.read(File.join(root, 'lib/a.rb'))
    ensure
      box&.cleanup
    end
  end

  # Regression: with the temporary directory inside the project, a sandbox must not copy itself (or another
  # worker's sandbox) recursively.
  def test_tmpdir_inside_the_project
    with_project('lib/a.rb' => 'A', 'tmp/.keep' => '') do |root|
      old = ENV['TMPDIR']
      ENV['TMPDIR'] = File.join(root, 'tmp')
      boxes = Array.new(2) { Mutaruby::Sandbox.new(root) }
      boxes.each do |b|
        assert b.dir.start_with?(File.join(root, 'tmp'))
        assert_equal ['.keep'], Dir.children(b.path('tmp'))
        assert_equal 'A', File.read(b.path('lib/a.rb'))
      end
    ensure
      ENV['TMPDIR'] = old
      boxes&.each(&:cleanup)
    end
  end

  def test_glob_excludes_match_paths_and_basenames
    with_project('a/log/x' => '1', 'b/keep' => '2', 'c.log' => '3') do |root|
      box = Mutaruby::Sandbox.new(root, excludes: ['log', '*.log'])
      refute File.exist?(box.path('a/log'))
      refute File.exist?(box.path('c.log'))
      assert File.exist?(box.path('b/keep'))
    ensure
      box&.cleanup
    end
  end
end
