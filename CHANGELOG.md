# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-10-12

mutaruby now scores 100% on its own code: every mutant is killed by a test or listed, with a checkable reason, in
`.mutaruby-ignore.yml`. Getting there found the bugs below.

### Fixed

- Processes that a test run leaves behind (a server, a forked worker) are now killed when the run ends, not only on
  timeout, so they cannot interfere with the next mutant.
- A project root given through a symlink (for example under `/tmp` on macOS) was copied into the sandboxes as an
  empty directory, so the baseline ran without the project.
- An ignore entry for a removed sole argument (`mutation: "x =>"`) never matched: the mutant's change text had a
  trailing space. Change texts are now whitespace-normalised the same way on both sides.
- Captured baseline output is decoded as UTF-8 even when Ruby's default external encoding is something else.

### Changed

- `literal-string` also mutates `%q()` and `%Q[]` strings.
- `argument-removal` no longer skips calls on the right-hand side of a multiple assignment.
- Option parsing is available as `Mutaruby::CLI#parse`; `Runner::Options.build` supplies the defaults.
- Each library file requires what it uses and loads on its own.

## [0.1.0] - 2026-10-11

First release.

### Added

- AST-based mutant generation with the `parser` gem and 36 documented operators: arithmetic, comparison and
  bitwise swaps; `&&`/`||` swap and operand drops; negation and unary-minus removal; condition negate/force true/force
  false (including loops); integer, float, string, symbol, boolean, nil, array and hash literals; range swap; return
  value and method-body replacement; statement deletion; argument removal; call-to-receiver and call-to-argument;
  predicate forcing; safe-navigation removal; `raise` removal; compound, `||=` and `&&=` assignments.
- Any shell command as the test oracle (exit 0 = survived, non-zero = killed).
- Each mutant runs in a fresh process inside a per-worker copy of the project; the working tree is never written.
- Baseline check: the unmodified code must pass the command first.
- Per-mutant timeout (default derived from the baseline), counted as a kill and reported separately; the whole
  process group is killed.
- Splicing at character offsets with a self-check that aborts on any mismatch between the replaced slice and the
  node's own source.
- Parallel workers (`--jobs`), file and glob targets, `--since REF` for changed files, include/exclude by method and
  by line, `--operators`/`--exclude-operators`, `--shard I/N`, and `# mutaruby:disable` comments.
- Ignore file for equivalent mutants, keyed by site (file, operator, line text, occurrence, method), with a required
  reason, ambiguity and staleness checks, `--strict-ignore` and `--suggest-ignore`.
- Human, JSON and JUnit XML reports, a mutation score and `--fail-under` for CI.

[0.1.1]: https://github.com/Atlas-Authorization/mutaruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/Atlas-Authorization/mutaruby/releases/tag/v0.1.0
