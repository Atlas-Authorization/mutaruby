# frozen_string_literal: true

require 'rbconfig'

module Mutaruby
  # Everything that differs between POSIX systems and Windows: how a test command is started, how its whole process
  # tree is stopped, and how sandboxes are named.
  module Platform
    # Linux, macOS and the BSDs: the command runs under /bin/sh as the leader of its own process group, and the group
    # is signalled as a whole.
    class Posix
      def name = 'posix'

      def spawn_args(command) = ['/bin/sh', '-c', command]

      def spawn_options = { pgroup: true }

      def temp_prefix = 'mutaruby-'

      # After a run ends, whatever is left of its process group is stopped too.
      def stop_leftovers? = true

      # graceful: SIGTERM, otherwise SIGKILL, to the process group led by pid.
      def stop_tree(pid, graceful:)
        Process.kill(graceful ? 'TERM' : 'KILL', -pid)
      rescue Errno::ESRCH, Errno::EPERM
        # the group is already gone
      end

      def alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
    end

    # Windows: the command string runs under cmd.exe (Process.spawn with a single string does that) in a new process
    # group, and the tree below the command's process is stopped with taskkill /T (without /F first, then with /F).
    class Windows
      # system: how taskkill is run (replaceable in tests).
      def initialize(system: ->(*argv) { Kernel.system(*argv, out: File::NULL, err: File::NULL) })
        @system = system
      end

      def name = 'windows'

      def spawn_args(command) = [command]

      def spawn_options = { new_pgroup: true }

      # Short: Windows paths are limited to 260 characters unless long paths are enabled.
      def temp_prefix = 'mr'

      # Not after a normal exit: taskkill /T finds the tree through the (now exited) parent process, and Windows may
      # already have reused its id for an unrelated process.
      def stop_leftovers? = false

      def stop_tree(pid, graceful:)
        @system.call('taskkill', '/T', *(graceful ? [] : ['/F']), '/PID', pid.to_s)
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
    end

    def self.windows?(host_os = RbConfig::CONFIG['host_os'])
      host_os.match?(/mswin|mingw|cygwin/)
    end

    def self.current
      @current ||= windows? ? Windows.new : Posix.new
    end
  end
end
