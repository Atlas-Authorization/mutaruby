# frozen_string_literal: true

# Measures coverage-based test selection: the same mutants, run once with the whole test command for every mutant
# and once with --coverage. Prints wall-clock times and checks that both runs reach the same verdicts.
#   bundle exec ruby script/benchmark-coverage.rb NAME ROOT "TEST COMMAND" [mutaruby options...]
require 'json'
require 'rbconfig'

name, root, command, *opts = ARGV
exe = File.expand_path('../exe/mutaruby', __dir__)
run = lambda do |extra|
  out = File.join(Dir.pwd, "bench-#{name}-#{extra.empty? ? 'full' : 'coverage'}.json")
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ok = system(RbConfig.ruby, exe, '-C', root, '-t', command, '-q', *opts, *extra, '--json', out)
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  abort "mutaruby failed (#{name})" unless ok
  report = JSON.parse(File.read(out))
  verdicts = report['mutants'].to_h { |m| [m['id'], m['status'].sub('timeout', 'killed')] }
  [seconds, verdicts, report['mutants'].count { |m| m['tests'] }]
end
full_s, full_v, = run.call([])
cov_s, cov_v, subset = run.call(['--coverage'])
same = full_v == cov_v
puts format('%-10s mutants %4d  whole command %7.1fs  --coverage %7.1fs  speed-up x%.1f  subset %d  same verdicts: %s',
            name, full_v.size, full_s, cov_s, full_s / cov_s, subset, same)
exit(same ? 0 : 1)
