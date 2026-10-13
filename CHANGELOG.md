# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-10-12

### Added

- `--coverage`: coverage-based test selection. The baseline run records, with Ruby's Coverage API and the test
  framework's per-test hooks, which tests execute which lines; each mutant then runs only those tests (Minitest and
  RSpec), and falls back to the whole command for load-time code, unreached lines and other test commands. The
  summary and the JSON report show how many mutants ran a subset.
- `--subject`: select methods by their place in the code (`Foo#bar`, `Foo.bar`, `Foo#*`, `Foo.*`, `Foo` with its
  nested namespaces, `Foo*`).
- Eight operators: `block-removal`, `method-swap`, `element-removal`, `regexp-never-match`, `yield-removal`,
  `super-removal`, `when-removal`, `rescue-removal`.
- `--unparser`: render rebuilt nodes (`element-removal`) with the MIT-licensed `unparser` gem, an optional extra.
  Text splicing, with its self-check, stays the default.

### Fixed

- An interrupted run starts no new mutant and waits for its workers to finish before it removes their sandboxes.
- On Windows, a forcibly stopped run is given time to exit for good before its sandbox is removed (the directory
  stays locked until then). A sandbox that still cannot be removed no longer hides the real error (Ctrl-C, a
  failing baseline); removal is also retried when the directory is not yet empty.
- With `--coverage`, Ruby processes started by the tests themselves (a test that runs another suite) are neither
  recorded nor filtered, and launcher processes (`bundle exec`, `rake`) do not overwrite the map.

### Changed

- The README's comparison credits mutant as the mature reference implementation and states that mutaruby is an
  independent, clean-room implementation that shares no code with it.

## [0.2.0] - 2026-10-12

### Added

- Windows support. The test command runs under `cmd.exe` in a new process group; on timeout the whole process tree
  is stopped with `taskkill /T` (graceful first, then `/F` after the grace period). Sandboxes get short names, writes
  and deletes are retried while a file is locked, and symlinks fall back to copies where Windows does not allow
  them. See "Windows notes" in the README.
- `Mutaruby::Platform`, which holds everything that differs between POSIX systems and Windows. The POSIX behaviour is
  unchanged.
- CI on Linux, macOS and Windows (Ruby 3.1 to 3.4), including a fixture run whose infinite-loop mutant must be
  stopped by the timeout.

### Fixed

- Files with CRLF line endings aborted the run with a splice self-check error: `parser` reads `\r\n` as `\n`, so its
  offsets did not match the file. Offsets are now mapped back to the file's own characters, and a mutant keeps the
  file's line endings (mixed endings included).
- Sources are read as bytes and decoded as UTF-8, with no newline conversion on Windows; ignore files are read as
  UTF-8 whatever the default external encoding.
- Sandbox removal no longer silently leaves files behind when one is locked.

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

[0.3.0]: https://github.com/Atlas-Authorization/mutaruby/releases/tag/v0.3.0
[0.2.0]: https://github.com/Atlas-Authorization/mutaruby/releases/tag/v0.2.0
[0.1.1]: https://github.com/Atlas-Authorization/mutaruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/Atlas-Authorization/mutaruby/releases/tag/v0.1.0
