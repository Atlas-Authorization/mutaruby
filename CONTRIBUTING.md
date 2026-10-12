# Contributing to mutaruby

Thanks for helping. Bug reports, operator ideas and pull requests are all welcome.

## Setting up

```sh
git clone https://github.com/Atlas-Authorization/mutaruby
cd mutaruby
bundle install
bundle exec rake test        # unit + end-to-end
bundle exec rake test:unit   # the fast part
```

You need Ruby 3.1 or newer on Linux or macOS.

## Layout

| Path | What it is |
|---|---|
| `lib/mutaruby/generator.rb` | the mutation operators (one AST walk) |
| `lib/mutaruby/splicer.rb` | the character-offset splice and its self-check |
| `lib/mutaruby/sandbox.rb` | the per-worker copy of the project |
| `lib/mutaruby/command.rb` | running the test command: fresh process, timeout, process-group kill |
| `lib/mutaruby/runner.rb` | baseline, workers, verdicts |
| `lib/mutaruby/selection.rb` | files, `--since`, method/line filters, shards |
| `lib/mutaruby/ignore_file.rb` | equivalent-mutant entries and site keys |
| `lib/mutaruby/reporters.rb` | human, JSON and JUnit output |
| `test/unit/` | fast tests; also the oracle when mutaruby mutates itself |
| `test/e2e/`, `test/fixtures/calc/` | the CLI against a small project with known killed, surviving, equivalent and timeout mutants |

## Guidelines

- **Add a test with every change.** Bug fixes get a regression test that fails without the fix.
- **New operators** need an entry in `Generator::OPERATORS`, a unit test that pins the exact changes they produce,
  a row in the README's operator table and a CHANGELOG line. Prefer operators that produce mutants a good test suite
  can kill; operators that are mostly equivalent create noise.
- **Do not weaken the correctness guarantees** (fresh process per mutant, never writing the working tree, the splice
  self-check, the baseline check). They each have a regression test.
- **Mutate mutaruby with mutaruby** for non-trivial changes: `bundle exec rake mutate` (use `--line` or `--method` to
  focus on what you changed) and look at the survivors.
- Keep the dependency footprint at `parser` alone.

## Releasing (maintainers)

1. Update `lib/mutaruby/version.rb` and `CHANGELOG.md`.
2. `gem build mutaruby.gemspec && gem push mutaruby-X.Y.Z.gem`
3. Tag `vX.Y.Z` and create a GitHub release from the changelog entry.
