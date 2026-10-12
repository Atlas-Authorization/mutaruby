# frozen_string_literal: true

require_relative 'lib/mutaruby/version'

Gem::Specification.new do |spec|
  spec.name = 'mutaruby'
  spec.version = Mutaruby::VERSION
  spec.authors = ['Atlas Authorization']
  spec.summary = 'Free, MIT-licensed mutation testing for Ruby'
  spec.description = 'mutaruby changes your code in small ways (mutants) and runs your test command against each ' \
                     'change. A mutant your tests do not notice is a gap in your tests. Works with any test command ' \
                     '(rspec, minitest, rake), runs every mutant in a fresh process inside a private copy of the project, ' \
                     'and reports a mutation score as text, JSON or JUnit XML.'
  spec.homepage = 'https://github.com/Atlas-Authorization/mutaruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues"
  }

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'CHANGELOG.md', 'LICENSE']
  spec.bindir = 'exe'
  spec.executables = ['mutaruby']
  spec.require_paths = ['lib']

  spec.add_dependency 'parser', '>= 3.2', '< 4'
end
