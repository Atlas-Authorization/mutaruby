# frozen_string_literal: true

require_relative '../test_helper'

class SandboxTest < Minitest::Test
  include TestHelpers

  def tree(dir)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).reject { |f| f.end_with?('/.') || f == '.' }.sort
  end

  def test_constants
    assert_equal %w[.git coverage], Mutaruby::Sandbox::DEFAULT_EXCLUDES
    assert_equal [10, 0.1, [Errno::EACCES, Errno::EBUSY, Errno::EPERM, Errno::ENOTEMPTY]],
                 [Mutaruby::Sandbox::RETRIES, Mutaruby::Sandbox::RETRY_DELAY, Mutaruby::Sandbox::LOCKED]
  end

  def test_copies_the_project_into_a_fresh_temporary_directory
    posix_only! # symlinks and modes
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
        assert_equal 'mutaruby-', sandbox_prefix
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
    posix_only!
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
    posix_only!
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
    pre = sandbox_prefix
    with_project('lib/a.rb' => 'A', 'tmp/.keep' => '', 'tmp/notes/x' => 'n', "tmp/#{pre}file" => 'f',
                 "lib/#{pre}helpers/h.rb" => 'H') do |root|
      with_env('TMPDIR' => File.join(root, 'tmp')) do
        boxes = Array.new(2) { Mutaruby::Sandbox.new(root) }
        boxes.each do |b|
          assert b.dir.start_with?(File.join(root, "tmp/#{pre}"))
          assert_equal %W[.keep #{pre}file notes notes/x], tree(b.path('tmp'))
          assert_equal 'H', File.read(b.path("lib/#{pre}helpers/h.rb"))
        end
      ensure
        boxes&.each(&:cleanup)
      end
    end
  end

  # The same through a symlinked TMPDIR: the sandbox is recognised by its real path.
  def test_tmpdir_inside_the_project_through_a_symlink
    posix_only!
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

  def test_portable_copy_keeps_content_and_times
    with_project('lib/a.rb' => "A\r\n", '.git/HEAD' => 'x') do |root|
      File.utime(Time.at(1_000_000), Time.at(1_000_000), File.join(root, 'lib/a.rb'))
      box = Mutaruby::Sandbox.new(root)
      assert_equal %w[lib lib/a.rb], tree(box.dir)
      assert_equal "A\r\n", File.binread(box.path('lib/a.rb'))
      assert_equal Time.at(1_000_000), File.mtime(box.path('lib/a.rb'))
    ensure
      box&.cleanup
    end
  end

  def test_the_platform_names_the_sandbox
    with_project('lib/a.rb' => 'A') do |root|
      box = Mutaruby::Sandbox.new(root, platform: Mutaruby::Platform::Windows.new)
      assert File.basename(File.dirname(box.dir)).start_with?('mr')
      refute File.basename(File.dirname(box.dir)).start_with?('mutaruby-')
    ensure
      box&.cleanup
    end
  end

  def test_retrying_locked_files
    n = 0
    assert_equal :ok, Mutaruby::Sandbox.retrying(delay: 0) { (n += 1) < 3 ? raise(Errno::EACCES) : :ok }
    assert_equal 3, n
    n = 0
    assert_raises(Errno::EBUSY) { Mutaruby::Sandbox.retrying(tries: 4, delay: 0) { n += 1; raise Errno::EBUSY } }
    assert_equal 4, n
    n = 0
    assert_raises(Errno::ENOENT) { Mutaruby::Sandbox.retrying(delay: 0) { n += 1; raise Errno::ENOENT } }
    assert_equal 1, n, 'other errors are not retried'
    n = 0
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Errno::EPERM) { Mutaruby::Sandbox.retrying(tries: 3, delay: 0.1) { n += 1; raise Errno::EPERM } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :>=, 0.2
    n = 0
    assert_raises(Errno::EACCES) { Mutaruby::Sandbox.retrying { n += 1; raise Errno::EACCES } }
    assert_equal 10, n
  end

  # Fails the first `times` calls of File.binwrite with EACCES, like a file still held open on Windows.
  def with_locked_writes(times)
    calls = 0
    File.singleton_class.alias_method(:real_binwrite, :binwrite)
    File.define_singleton_method(:binwrite) do |*a|
      calls += 1
      raise Errno::EACCES if calls <= times

      real_binwrite(*a)
    end
    yield
    calls
  ensure
    File.singleton_class.alias_method(:binwrite, :real_binwrite)
  end

  def test_writes_are_retried_while_locked
    with_project('lib/a.rb' => 'orig') do |root|
      box = Mutaruby::Sandbox.new(root)
      seen = nil
      calls = with_locked_writes(2) { box.with_file('lib/a.rb', 'mutant', 'orig') { seen = File.read(box.path('lib/a.rb')) } }
      assert_equal ['mutant', 'orig', 4], [seen, File.read(box.path('lib/a.rb')), calls]
    ensure
      box&.cleanup
    end
  end

  def test_cleanup_retries_and_is_idempotent
    with_project('lib/a.rb' => 'A') do |root|
      box = Mutaruby::Sandbox.new(root)
      base = File.dirname(box.dir)
      fails = 1
      FileUtils.singleton_class.alias_method(:real_rm_r, :rm_r)
      FileUtils.define_singleton_method(:rm_r) do |*a, **k|
        raise Errno::EBUSY if (fails -= 1) >= 0

        real_rm_r(*a, **k)
      end
      begin
        box.cleanup
      ensure
        FileUtils.singleton_class.alias_method(:rm_r, :real_rm_r)
      end
      refute File.exist?(base)
      box.cleanup
    end
  end

  # Without the symlink privilege (Windows), a link is replaced by a copy of its target; a dangling link is skipped.
  def test_symlink_fallback
    posix_only! # creating the links needs the privilege
    with_project('lib/a.rb' => 'A', 'dir/x' => 'X') do |root|
      File.symlink('lib/a.rb', File.join(root, 'link.rb'))
      File.symlink('dir', File.join(root, 'dlink'))
      File.symlink('nowhere', File.join(root, 'dangling'))
      File.singleton_class.alias_method(:real_symlink, :symlink)
      File.define_singleton_method(:symlink) { |*| raise Errno::EPERM }
      begin
        box = Mutaruby::Sandbox.new(root)
      ensure
        File.singleton_class.alias_method(:symlink, :real_symlink)
      end
      refute File.symlink?(box.path('link.rb'))
      assert_equal 'A', File.read(box.path('link.rb'))
      assert_equal 'X', File.read(box.path('dlink/x'))
      refute File.exist?(box.path('dangling'))
      refute File.symlink?(box.path('dangling'))
      [NotImplementedError, Errno::EACCES].each do |err|
        File.singleton_class.alias_method(:real_symlink, :symlink)
        File.define_singleton_method(:symlink) { |*| raise err }
        begin
          other = Mutaruby::Sandbox.new(root)
        ensure
          File.singleton_class.alias_method(:symlink, :real_symlink)
        end
        assert_equal 'A', File.read(other.path('link.rb'))
        other.cleanup
      end
    ensure
      box&.cleanup
    end
  end
end
