# frozen_string_literal: true

require_relative '../test_helper'

class SandboxTest < Minitest::Test
  include TestHelpers

  def tree(dir)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).reject { |f| f.end_with?('/.') || f == '.' }.sort
  end

  def test_constants
    assert_equal %w[.git coverage], Mutaruby::Sandbox::DEFAULT_EXCLUDES
    assert_equal 'mutaruby-', Mutaruby::Sandbox::PREFIX
  end

  def test_copies_the_project_into_a_fresh_temporary_directory
    with_project('lib/a.rb' => 'A', '.git/HEAD' => 'x', 'coverage/i.html' => 'c', 'tmp/big' => 'b', '.rspec' => 'r',
                 'bin/run' => "#!/bin/sh\n") do |root|
      File.symlink('lib/a.rb', File.join(root, 'link.rb'))
      File.chmod(0o755, File.join(root, 'bin/run'))
      File.utime(Time.at(1_000_000), Time.at(1_000_000), File.join(root, 'lib/a.rb'))
      box = Mutaruby::Sandbox.new(root, excludes: ['tmp'])
      begin
        base = File.dirname(box.dir)
        assert_equal File.join(base, 'proj'), box.dir
        assert_equal File.realpath(Dir.tmpdir), File.realpath(File.dirname(base))
        assert File.basename(base).start_with?('mutaruby-')
        assert_equal File.join(box.dir, 'lib/a.rb'), box.path('lib/a.rb')
        assert_equal %w[.rspec bin bin/run lib lib/a.rb link.rb], tree(box.dir)
        assert_equal 'A', File.read(box.path('lib/a.rb'))
        assert_equal 'lib/a.rb', File.readlink(box.path('link.rb'))
        assert File.executable?(box.path('bin/run'))
        assert_equal Time.at(1_000_000), File.mtime(box.path('lib/a.rb'))
      ensure
        box.cleanup
      end
      refute File.exist?(base)
    end
  end

  def test_relative_root
    with_project('lib/a.rb' => 'A') do |root|
      Dir.chdir(root) do
        box = Mutaruby::Sandbox.new('.')
        assert_equal 'proj', File.basename(box.dir)
        assert_equal 'A', File.read(box.path('lib/a.rb'))
      ensure
        box&.cleanup
      end
    end
  end

  # Regression: a root given through a symlink (like /tmp on macOS) is copied in full, not as an empty directory.
  def test_root_through_a_symlink
    with_project('lib/a.rb' => 'A') do |root|
      Dir.mktmpdir do |d|
        link = File.join(d, 'proj-link')
        File.symlink(root, link)
        box = Mutaruby::Sandbox.new(link)
        assert_equal 'proj', File.basename(box.dir)
        assert_equal %w[lib lib/a.rb], tree(box.dir)
      ensure
        box&.cleanup
      end
    end
  end

  def test_special_files_are_not_copied
    with_project('lib/a.rb' => 'A') do |root|
      File.mkfifo(File.join(root, 'pipe'))
      box = Mutaruby::Sandbox.new(root)
      assert_equal %w[lib lib/a.rb], tree(box.dir)
    ensure
      box&.cleanup
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

  # Patterns match the relative path (a `*` does not cross `/`) or the base name; both match dotfiles.
  def test_exclude_patterns
    files = { 'a/log/x' => '1', 'b/keep' => '2', 'c.log' => '3', 'conf/.env' => '4', 'p/q/x' => '5', 'p/x' => '6',
              'sub/.bashrc' => '7', 'sub/keep' => '8' }
    with_project(files) do |root|
      box = Mutaruby::Sandbox.new(root, excludes: ['log', '*.log', 'conf/*', 'p/x', '*rc'])
      assert_equal %w[a b b/keep conf p p/q p/q/x sub sub/keep], tree(box.dir)
    ensure
      box&.cleanup
    end
    with_project('a/b/x' => '1', 'a/x' => '2') do |root|
      box = Mutaruby::Sandbox.new(root, excludes: ['*/x'])
      assert_equal %w[a a/b a/b/x], tree(box.dir)
    ensure
      box&.cleanup
    end
  end

  # Regression: with the temporary directory inside the project (for example TMPDIR=./tmp), a sandbox must not copy
  # itself or another worker's sandbox, but everything else in that directory is copied.
  def test_tmpdir_inside_the_project
    with_project('lib/a.rb' => 'A', 'tmp/.keep' => '', 'tmp/notes/x' => 'n', 'tmp/mutaruby-file' => 'f',
                 'lib/mutaruby-helpers/h.rb' => 'H') do |root|
      with_env('TMPDIR' => File.join(root, 'tmp')) do
        boxes = Array.new(2) { Mutaruby::Sandbox.new(root) }
        boxes.each do |b|
          assert b.dir.start_with?(File.join(root, 'tmp/mutaruby-'))
          assert_equal %w[.keep mutaruby-file notes notes/x], tree(b.path('tmp'))
          assert_equal 'H', File.read(b.path('lib/mutaruby-helpers/h.rb'))
        end
      ensure
        boxes&.each(&:cleanup)
      end
    end
  end

  # The same through a symlinked TMPDIR: the sandbox is recognised by its real path.
  def test_tmpdir_inside_the_project_through_a_symlink
    with_project('lib/a.rb' => 'A', 'tmp/.keep' => '') do |root|
      Dir.mktmpdir do |outside|
        link = File.join(outside, 'tmp-link')
        File.symlink(File.join(root, 'tmp'), link)
        with_env('TMPDIR' => link) do
          box = Mutaruby::Sandbox.new(root)
          assert_equal %w[.keep], tree(box.path('tmp'))
        ensure
          box&.cleanup
        end
      end
    end
  end
end
