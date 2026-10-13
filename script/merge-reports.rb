# frozen_string_literal: true

# Merges the JSON reports of a sharded self-mutation run (--shard I/N) and checks them as one run would:
#   ruby -Ilib script/merge-reports.rb IGNORE_FILE REPORT.json...
# Exit 0 when no mutant survived and every ignore entry matched an equivalent mutant in some shard.
require 'json'
require 'mutaruby'

ignore_file, *paths = ARGV
mutants = paths.flat_map { |p| JSON.parse(File.read(p))['mutants'] }
abort 'no reports' if mutants.empty?
ids = mutants.map { |m| m['id'] }
abort "shards overlap or repeat: #{ids.size} mutants, #{ids.uniq.size} distinct ids" unless ids.size == ids.uniq.size

to_mutation = lambda do |m|
  Mutaruby::Mutation.new(file: m['file'], operator: m['operator'], orig: m['orig'], repl: m['repl'],
                         line_text: m['line_text'], occurrence: m['occurrence'], method: m['method'])
end
ignore = Mutaruby::IgnoreFile.load(ignore_file)
# A survivor that the ignore file lists is equivalent (as the runner itself would have reported it with this file).
mutants.each { |m| m['status'] = 'equivalent' if m['status'] == 'survived' && ignore.match(to_mutation.call(m)) }

counts = mutants.group_by { |m| m['status'] }.transform_values(&:size)
killed = counts.fetch('killed', 0) + counts.fetch('timeout', 0)
survived = mutants.select { |m| m['status'] == 'survived' }
puts "mutants: #{mutants.size}  killed: #{killed} (#{counts.fetch('timeout', 0)} by timeout)  " \
     "survived: #{survived.size}  equivalent: #{counts.fetch('equivalent', 0)}"
survived.each { |m| puts "SURVIVED #{m['file']}:#{m['lineno']} #{m['label']}" }

matched = mutants.select { |m| m['status'] == 'equivalent' }.filter_map { |m| ignore.match(to_mutation.call(m)) }
stale = ignore.entries - matched
stale.each { |e| puts "STALE #{e.label}" }
exit(survived.empty? && stale.empty? ? 0 : 1)
