# frozen_string_literal: true

require 'fileutils'
require 'find'
require 'tmpdir'
require_relative 'platform'

module Mutaruby
  # A private copy of the project. Every test-command run happens inside one, so the user's files are never written:
  # a crash, a timeout or a Ctrl-C in the middle of a run cannot leave a mutant behind in the working tree.
  #
  # Each worker owns one sandbox. A mutant is written into it, the test command runs, and the original file content
  # is written back before the next mutant.
  class Sandbox
    DEFAULT_EXCLUDES = %w[.git coverage].freeze
    # Writes and deletes are retried this many times, RETRY_DELAY seconds apart, while the file is locked (on Windows a
    # process that is still exiting, or a virus scanner, can hold it for a moment).
    RETRIES = 10
    RETRY_DELAY = 0.1
    LOCKED = [Errno::EACCES, Errno::EBUSY, Errno::EPERM].freeze

    # Runs the block, retrying while it raises one of the LOCKED errors.
    def self.retrying(tries: RETRIES, delay: RETRY_DELAY)
      attempt = 1
      begin
        yield
      rescue *LOCKED
        raise if attempt >= tries

        attempt += 1
        sleep delay
        retry
      end
    end

    attr_reader :dir

    def initialize(root, excludes: [], platform: Platform.current)
      # The real path: Find does not descend into a symlink, so a root reached through one (/tmp on macOS) would
      # otherwise be copied as an empty directory.
      @root = File.realpath(root)
      @excludes = DEFAULT_EXCLUDES + excludes
      @prefix = platform.temp_prefix
      @base = Dir.mktmpdir(@prefix)
      @tmp_parent = File.realpath(File.dirname(@base))
      @dir = File.join(@base, File.basename(@root))
      copy_tree
    end

    def path(rel)
      File.join(@dir, rel)
    end

    # Writes `text` to `rel` inside the sandbox, yields, and restores the original bytes afterwards (also on error).
    def with_file(rel, text, original)
      target = path(rel)
      begin
        Sandbox.retrying { File.binwrite(target, text) }
        yield
      ensure
        Sandbox.retrying { File.binwrite(target, original) }
      end
    end

    # Removes the sandbox. Unlike rm_rf, this does not silently leave a locked file behind: it retries, then raises.
    def cleanup
      Sandbox.retrying { FileUtils.rm_r(@base) if File.exist?(@base) }
    end

    private

    def excluded?(rel)
      @excludes.any? do |pat|
        File.fnmatch?(pat, rel, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          File.fnmatch?(pat, File.basename(rel), File::FNM_DOTMATCH)
      end
    end

    # A sandbox directory (this one or another worker's). When the temporary directory lies inside the project (for
    # example TMPDIR=./tmp), copying it would copy the sandbox into itself. Paths found under the real root are real.
    def sandbox?(path)
      File.directory?(path) && File.basename(path).start_with?(@prefix) &&
        File.dirname(path) == @tmp_parent
    end

    # A symlink is copied as a symlink. Where that is not allowed (Windows without the symlink privilege), what it
    # points to is copied instead; a dangling link is skipped.
    def link(src, dest)
      File.symlink(File.readlink(src), dest)
    rescue NotImplementedError, Errno::EPERM, Errno::EACCES
      FileUtils.cp_r(src, dest, dereference_root: true) if File.exist?(src)
    end

    def copy_tree
      FileUtils.mkdir_p(@dir)
      Find.find(@root) do |src|
        next if src == @root

        rel = src.delete_prefix("#{@root}/")
        Find.prune if excluded?(rel) || sandbox?(src)
        dest = File.join(@dir, rel)
        st = File.lstat(src)
        if st.symlink?
          link(src, dest)
        elsif st.directory?
          FileUtils.mkdir_p(dest)
        elsif st.file? # not sockets, FIFOs or devices: copying a FIFO would block
          FileUtils.cp(src, dest, preserve: true)
        end
      end
    end
  end
end
