# frozen_string_literal: true

require 'fileutils'
require 'find'
require 'tmpdir'

module Mutaruby
  # A private copy of the project. Every test-command run happens inside one, so the user's files are never written:
  # a crash, a timeout or a Ctrl-C in the middle of a run cannot leave a mutant behind in the working tree.
  #
  # Each worker owns one sandbox. A mutant is written into it, the test command runs, and the original file content
  # is written back before the next mutant.
  class Sandbox
    DEFAULT_EXCLUDES = %w[.git coverage].freeze

    attr_reader :dir

    def initialize(root, excludes: [], prefix: 'mutaruby-')
      @root = File.expand_path(root)
      @excludes = DEFAULT_EXCLUDES + excludes
      @prefix = prefix
      @base = Dir.mktmpdir(prefix)
      @dir = File.join(@base, File.basename(@root))
      copy_tree
    end

    def path(rel)
      File.join(@dir, rel)
    end

    # Writes `text` to `rel` inside the sandbox, yields, and restores the original bytes afterwards (also on error).
    def with_file(rel, text, original)
      target = path(rel)
      File.binwrite(target, text)
      yield
    ensure
      File.binwrite(target, original) if target
    end

    def cleanup
      FileUtils.rm_rf(@base)
    end

    private

    def excluded?(rel)
      @excludes.any? do |pat|
        File.fnmatch?(pat, rel, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          File.fnmatch?(pat, File.basename(rel), File::FNM_DOTMATCH)
      end
    end

    # A sandbox directory (this one or another worker's). When the temporary directory lies inside the project (for
    # example TMPDIR=./tmp), copying it would copy the sandbox into itself.
    def sandbox?(path)
      File.basename(path).start_with?(@prefix) && File.directory?(path) &&
        File.realpath(File.dirname(path)) == File.realpath(File.dirname(@base))
    end

    def copy_tree
      FileUtils.mkdir_p(@dir)
      Find.find(@root) do |src|
        next if src == @root

        rel = src.delete_prefix("#{@root}/")
        if excluded?(rel) || sandbox?(src)
          Find.prune
          next
        end
        dest = File.join(@dir, rel)
        st = File.lstat(src)
        if st.symlink?
          File.symlink(File.readlink(src), dest)
        elsif st.directory?
          FileUtils.mkdir_p(dest)
        elsif st.file?
          FileUtils.cp(src, dest, preserve: true)
        end
      end
    end
  end
end
