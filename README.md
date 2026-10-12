# mutaruby

[![CI](https://github.com/Atlas-Authorization/mutaruby/actions/workflows/ci.yml/badge.svg)](https://github.com/Atlas-Authorization/mutaruby/actions/workflows/ci.yml)
![mutation score on its own code: 100%](https://img.shields.io/badge/self%20mutation%20score-100%25-brightgreen)

Free, MIT-licensed mutation testing for Ruby.

mutaruby is mutation-tested with itself. In version 0.2.0, all 3,812 mutants of its own code are accounted for:
3,806 are killed by its tests (521 of them by timeout), and the other 6 are true equivalents, each listed in
[`.mutaruby-ignore.yml`](.mutaruby-ignore.yml) with a reason you can check. `bundle exec rake mutate` reproduces the
run; it fails on any surviving mutant or stale ignore entry.

mutaruby makes small, deliberate changes to your code, one at a time, and runs your test command against each change.
If your tests still pass, the change (the *mutant*) **survived**, and that points to code your tests do not really check.

```
$ mutaruby -t "bundle exec rspec"
.......S.........T......e....

Surviving mutants (not detected by the test command):

  lib/pricing.rb:14 in Pricing#discount  [#7]
    comparison: > => >=
    -     return 0 if total > 100
    +     return 0 if total >= 100

mutaruby summary
  files:       3
  mutants:     29
  killed:      27 (1 by timeout)
  survived:    1
  equivalent:  1 (ignore file)
  score:       96.43%  = killed / (mutants - equivalent)
  time:        11.2s (baseline 0.84s, timeout 8s, jobs 8)
```

The survivor above tells you that no test checks a total of exactly 100.

## Contents

- [What mutation testing is](#what-mutation-testing-is)
- [Install](#install)
- [Quickstart](#quickstart)
- [CLI reference](#cli-reference)
- [Mutation operators](#mutation-operators)
- [Coverage-based test selection](#coverage-based-test-selection)
- [Equivalent mutants: the ignore file](#equivalent-mutants-the-ignore-file)
- [Using it in CI](#using-it-in-ci)
- [Output formats](#output-formats)
- [How it compares with mutant](#how-it-compares-with-mutant)
- [Design notes](#design-notes)
- [Windows notes](#windows-notes)
- [Limitations](#limitations)
- [Contributing, security, licence](#contributing-security-licence)

## What mutation testing is

Line coverage tells you which code your tests *ran*. It does not tell you whether they would *notice* if that code were
wrong. A test that calls `discount(150)` and only checks that it returns something covers the `>` comparison but would
pass just as well with `>=`, `<` or `true` in its place.

Mutation testing measures that directly:

1. Run the test suite once on the unmodified code. It must pass (the **baseline**).
2. For every mutant, a copy of the code with one small change such as `>` to `>=`, `&&` to `||`, `x + 1` to
   `x - 1` or a deleted statement, run the tests again.
3. If the tests fail, the mutant is **killed**: your tests detect that change. If they pass, it **survived**.
4. The **mutation score** is `killed / (mutants - equivalent)`.

Some mutants cannot be killed because they do not change behaviour (for example `x < 0` vs `x <= 0` when `x == 0`
produces the same result either way). They are **equivalent** mutants; you list them in an
[ignore file](#equivalent-mutants-the-ignore-file) with a reason, and they no longer count against the score.

## Install

```sh
gem install mutaruby
```

or in a Gemfile:

```ruby
group :development, :test do
  gem 'mutaruby', require: false
end
```

mutaruby needs Ruby 3.1 or newer and depends only on the [`parser`](https://github.com/whitequark/parser) gem. It runs
on Linux, macOS and Windows (see [Windows notes](#windows-notes)); CI tests all three.

## Quickstart

mutaruby runs any shell command as the test oracle: **exit status 0 means the mutant survived, anything else means it
was killed**. By default it mutates `lib/**/*.rb`.

### With RSpec

```sh
mutaruby -t "bundle exec rspec"
# only one file, and run only the spec that covers it (much faster):
mutaruby -t "bundle exec rspec spec/pricing_spec.rb" lib/pricing.rb
```

### With minitest

```sh
mutaruby -t "bundle exec rake test"
# or without rake:
mutaruby -t "ruby -Ilib -Itest -e 'Dir[\"test/**/*_test.rb\"].each { |f| require File.expand_path(f) }'"
```

### Any command

```sh
mutaruby -t "bin/rails test test/models" "app/models/**/*.rb"
mutaruby -t "make check" lib/parser.rb
```

Tips:

- **Make the test command fast and fail fast.** It runs once per mutant. `rspec --fail-fast` stops at the first
  failure, which is all mutaruby needs.
- **Point it at the tests that matter** for the files you mutate.
- **Start small**: one file, or `--since main` to mutate only what your branch changed.
- Use `--list` to see the mutants without running anything.

## CLI reference

```
mutaruby --test COMMAND [options] [FILE|GLOB ...]
```

Positional arguments are files or globs relative to the project root. The default is `lib/**/*.rb`.

### Test oracle

| Option | Meaning |
|---|---|
| `-t`, `--test COMMAND` | **Required.** Shell command that runs your tests: run with `/bin/sh -c` on Linux and macOS, with `cmd.exe` on Windows. Exit 0 means the mutant survived, non-zero means killed. |
| `-C`, `--root DIR` | Project root (default: the current directory). This is the directory copied into each sandbox, and the command runs there. |
| `-j`, `--jobs N` | Parallel workers (default: the number of CPUs). Each worker has its own copy of the project. |
| `--coverage` | Run, for each mutant, only the tests that execute its lines (Minitest and RSpec). See [Coverage-based test selection](#coverage-based-test-selection). |
| `--unparser` | Render rebuilt nodes (the `element-removal` operator) with the [`unparser`](https://github.com/mbj/unparser) gem instead of from the source text. Needs `gem install unparser`. |
| `--timeout SECONDS` | Per-mutant time limit. A mutant that exceeds it (an infinite loop, say) is killed together with every process it started and counted as **killed, by timeout**. The default is `baseline time x factor + 5` seconds. |
| `--timeout-factor F` | The factor for the default timeout (default: 3). |
| `--copy-exclude GLOB` | Do not copy matching paths into the sandboxes (repeatable). `.git` and `coverage` are never copied. Matches against the relative path and against the base name, e.g. `--copy-exclude node_modules --copy-exclude 'log/*'`. |

The command gets these environment variables: `MUTARUBY=1`, and while a mutant runs `MUTARUBY_MUTANT_ID` (its id) and
`MUTARUBY_FILE` (the mutated file, relative to the root).

### Selection

| Option | Meaning |
|---|---|
| `--since REF` | Only mutate files changed since a git ref: committed, staged and unstaged changes plus new untracked files (`git diff --name-only REF` and `git ls-files --others --exclude-standard`), intersected with the file arguments. |
| `--subject PATTERN` | Only mutants in these methods (repeatable): `Foo#bar` (instance method), `Foo.bar` (singleton method), `Foo#*` / `Foo.*` (all of one kind), `Foo` or `Foo::Bar` (every method of that namespace and of the namespaces nested in it), `Foo*` (a glob over namespaces). |
| `--method PATTERN` | Only mutants inside matching methods (repeatable). The pattern is a glob matched against the qualified name (`Pricing#discount` for an instance method, `Pricing.build` for a singleton method) or the bare name (`discount`). `Pricing#*` selects every instance method of `Pricing`. |
| `--exclude-method PATTERN` | Skip mutants inside matching methods (repeatable). |
| `--line SPEC` | Only mutants starting on these lines (repeatable). `SPEC` is `[FILE:]LINE` or `[FILE:]FROM-TO`, e.g. `lib/a.rb:10-20` or `42`. |
| `--exclude-line SPEC` | Skip mutants on these lines (repeatable). |
| `--operators LIST` | Only these operators (comma-separated ids; globs allowed, e.g. `condition-*,comparison`). |
| `--exclude-operators LIST` | Skip these operators. |
| `--shard I/N` | Run only shard `I` of `N` (1-based). Mutants are numbered in a stable order (files sorted, then source order) and mutant `k` belongs to shard `k mod N + 1`, so the shards of one run are disjoint and together cover every mutant. |

A line containing the comment `mutaruby:disable` is never mutated:

```ruby
LOG_PREFIX = '[app]' # mutaruby:disable
```

### Equivalent mutants

| Option | Meaning |
|---|---|
| `--ignore-file PATH` | The ignore file (default: `.mutaruby-ignore.yml` in the root, when it exists). |
| `--strict-ignore` | Exit 1 if an ignore entry matches no surviving mutant (it is stale; see below). |
| `--suggest-ignore` | After the run, print ignore-file entries for every survivor, with an empty `reason` for you to fill in. Keep only real equivalents. |

### Output

| Option | Meaning |
|---|---|
| `--json PATH` | Write a JSON report. `-` writes it to stdout (the human summary then goes to stderr). |
| `--junit PATH` | Write a JUnit-style XML report (`-` for stdout). |
| `--fail-under PERCENT` | Exit 1 when the mutation score is below `PERCENT`. |
| `--list` | Print the selected mutants (id, location, method, change) and exit without running anything. Needs no `--test`. |
| `--list-operators` | Print every operator id with a description. |
| `-q`, `--quiet` | No progress marks. Progress marks go to stderr: `.` killed, `T` killed by timeout, `S` survived, `e` equivalent. |
| `-v`, `--verbose` | Also list timeouts and equivalent mutants in the summary. |
| `--version`, `-h`/`--help` | |

### Exit status

| Status | Meaning |
|---|---|
| 0 | The run completed (and met `--fail-under`, if given). |
| 1 | The score is below `--fail-under`, or `--strict-ignore` found stale entries. |
| 2 | Usage error, invalid ignore file, or the **baseline failed**: the test command does not pass on the unmodified code. |
| 130 | Interrupted. |

## Mutation operators

Every mutant is one edit at one place. Mutants that would not parse, and mutants whose text equals an earlier
mutant's, are dropped before anything runs. `--list-operators` prints this list.

| Operator | Change | Example |
|---|---|---|
| `arithmetic` | swaps `+ -`, `* /`, `%` to `*`, `**` to `*` | `a + b` to `a - b` |
| `comparison` | boundary and equality swaps: `==` and `!=`, `<` to `<=`, `<=` to `<`, `>` to `>=`, `>=` to `>`, `<=>` to `==`, `===` to `!=`, `=~` and `!~` | `n > 0` to `n >= 0` |
| `bitwise` | swaps `&` and `\|`, `^` to `&`, `<<` and `>>` | `flags & MASK` to `flags \| MASK` |
| `logical-swap` | `&&` and `\|\|`, `and` and `or` | `a && b` to `a \|\| b` |
| `logical-drop-left` | keeps only the right operand | `a && b` to `b` |
| `logical-drop-right` | keeps only the left operand | `a && b` to `a` |
| `negation-removal` | removes `!` / `not` | `!valid` to `valid` |
| `unary-minus-removal` | removes unary minus | `-delta` to `delta` |
| `condition-negate` | negates the condition of `if`, `unless`, `elsif`, ternaries and modifiers | `if ok` to `if !(ok)` |
| `condition-true` | forces the condition true | `if ok` to `if true` |
| `condition-false` | forces the condition false | `if ok` to `if false` |
| `loop-condition-negate` | negates a `while`/`until` condition | `while i < n` to `while !(i < n)` |
| `loop-condition-false` | a `while` loop never runs | `while i < n` to `while false` |
| `literal-int` | an integer becomes n+1, n-1, 0 and 1 (each distinct value once) | `retries = 3` to `4`, `2`, `0`, `1` |
| `literal-float` | a float becomes 0.0 and x+1.0 | `0.5` to `0.0`, `1.5` |
| `literal-string` | a quoted string (`'...'`, `"..."`, `%q()`, `%Q[]`) becomes empty; an empty one becomes `"mutaruby"` | `'admin'` to `''` |
| `literal-symbol` | a `:symbol` becomes `:__mutaruby__` | `:read` to `:__mutaruby__` |
| `literal-boolean` | `true` and `false` | `strict = true` to `strict = false` |
| `literal-nil` | `nil` becomes `true` | `cache = nil` to `cache = true` |
| `literal-array` | a non-empty array literal becomes `[]` | `[1, 2]` to `[]` |
| `literal-hash` | a non-empty hash literal becomes `{}` | `{ a: 1 }` to `{}` |
| `range-swap` | inclusive and exclusive ranges (not endless ranges, where both mean the same) | `0..n` to `0...n` |
| `return-nil` | an explicit return value becomes `nil` | `return total` to `return nil` |
| `method-body-nil` | a method body becomes `nil` | `def total = a + b` to `def total = nil` |
| `method-body-bool` | the body of a predicate method (`def x?`) becomes `true`, and `false` | |
| `statement-delete` | one statement of a multi-statement body becomes `nil` (class, module and method definitions and bare `private`-style calls are not deleted) | `log(x)` to `nil` |
| `argument-removal` | one argument is removed from a call (calls with up to 6 arguments; declarations such as `require`, `attr_reader`, `include` and `raise` are left alone) | `f(a, b)` to `f(b)` and `f(a)` |
| `call-to-receiver` | a method call is replaced by its receiver | `name.strip` to `name` |
| `call-to-argument` | a method call is replaced by its first argument | `list.fetch(i)` to `i` |
| `predicate-true` | a predicate call becomes `true` (except `block_given?`, `nil?`, `frozen?`, `respond_to?`) | `user.admin?` to `true` |
| `predicate-false` | a predicate call becomes `false` | `user.admin?` to `false` |
| `safe-navigation` | `&.` becomes `.` | `user&.name` to `user.name` |
| `raise-removal` | a `raise` / `fail` becomes `nil` | `raise ArgumentError unless ok` to `nil unless ok` |
| `op-assign` | swaps compound assignments: `+=` and `-=`, `*=` and `/=`, `\|=` and `&=`, `<<=` and `>>=` | `i += 1` to `i -= 1` |
| `or-assign` | `\|\|=` becomes `=` | `@x \|\|= load` to `@x = load` |
| `and-assign` | `&&=` becomes `=` | `a &&= b` to `a = b` |
| `block-removal` | a call loses its block | `list.map { \|x\| f(x) }` to `list.map` |
| `method-swap` | a method becomes its counterpart: `first`/`last`, `min`/`max`, `min_by`/`max_by`, `any?`/`all?`, `select`/`reject` (and `filter`), `upcase`/`downcase`, `floor`/`ceil`, `succ`/`pred`, `keys`/`values`, `start_with?`/`end_with?`, `take`/`drop`, `take_while`/`drop_while`, `push`/`unshift`, `pop`/`shift` | `items.first` to `items.last` |
| `element-removal` | one element of a bracketed array or braced hash removed (literals with 2 to 6 elements) | `[a, b]` to `[b]` and `[a]` |
| `regexp-never-match` | a regexp literal becomes one that matches nothing | `/\A\d+\z/` to `/(?!)/` |
| `yield-removal` | `yield` becomes `nil` | `yield(item)` to `nil` |
| `super-removal` | `super` becomes `nil` | `super(name)` to `nil` |
| `when-removal` | one `when` branch of a `case` removed | |
| `rescue-removal` | one `rescue` clause removed | |

Strings inside interpolations, heredocs, `%w[]` arrays and the arguments of `require`-style declarations are not
mutated, and neither are symbols used as hash keys (`a: 1`).

## Coverage-based test selection

Most mutants are reached by only a few tests, yet by default every mutant runs the whole test command. With
`--coverage`, mutaruby first finds out which tests execute which lines, then runs each mutant against just those
tests:

```sh
mutaruby -t "bundle exec rspec" --coverage
mutaruby -t "bundle exec rake test" --coverage
```

How it works:

1. The baseline run (which has to pass anyway) is made with a small probe loaded into the test process
   (`RUBYLIB` plus `RUBYOPT=-rmutaruby_probe`). The probe uses Ruby's `Coverage` API and the test framework's
   per-test hooks to record, for every test, the lines of the project it executes. Tests are identified as
   `Class#test_name` for Minitest and by the example id (`./spec/a_spec.rb[1:2]`) for RSpec.
2. For each mutant, the tests that execute any of its lines are written to a file, and the run loads the probe in
   selection mode, which tells Minitest or RSpec to run only those tests. The test command itself is unchanged.
3. A mutant runs the **whole** command instead when one of its lines ran while the code was being loaded (a class
   body, a constant, a method definition line), when no test reaches its lines, or when the baseline recorded no
   Minitest or RSpec tests at all (mutaruby then prints a warning).

What it saves depends on the suite. Measured on GitHub Actions (`script/benchmark-coverage.rb`, 4 workers), with the
same verdicts both ways:

| Project | Mutants | Whole test command | `--coverage` |
|---|---|---|---|
| mutaruby's own unit suite (a 1/25 sample of its mutants) | 199 | 3,788 s | 2,276 s (1.7x faster) |
| `test/fixtures/calc` (5 tests, Minitest or RSpec) | 43 | 13 s | 13 s |

A small suite gains nothing: starting Ruby costs more than its tests. The larger and slower the suite, and the fewer
tests reach each line, the bigger the win.

The summary shows how many mutants ran a subset, and the JSON report has, per mutant, the number of tests it ran
(`tests`, or `null` for the whole command). Selection assumes that tests are independent of each other: a test that
only passes after another one has run can make a mutant look killed.

## Equivalent mutants: the ignore file

`.mutaruby-ignore.yml` (or the file given to `--ignore-file`) is a YAML list. Each entry names one **mutation site** and
must say **why** the mutant is equivalent:

```yaml
- file: lib/pricing.rb            # relative to the project root
  operator: comparison            # operator id
  line: "return 0 if total < 0"   # the source line, leading/trailing whitespace ignored
  occurrence: 2                   # the 2nd line with exactly this text in the file; required when the text is not unique
  method: "Pricing#discount"      # optional: the enclosing method
  mutation: "< => <="             # optional: only this change at the site (as printed by --list / the JSON "change")
  lineno: 41                      # optional: a hint for humans, never used for matching
  reason: "total == 0 returns 0 on both paths"   # required, non-empty
```

The key is **file + operator + line text + occurrence + method**, not the line number. Line numbers move whenever
code above them changes; the text of the line does not. So an entry keeps working while you edit other code, and it
stops matching when the line itself changes, which is exactly when the "equivalent" verdict needs another look.

- An entry without `mutation` covers every mutant of that operator at that site. Add `mutation` to cover one change only.
- An entry whose line text appears more than once in the file must have an `occurrence`, otherwise mutaruby refuses
  the file as **ambiguous** (exit 2). An entry whose line no longer exists is refused as **stale** (exit 2).
- After a full run (no `--method`, `--line`, `--operators` or `--shard` filter), an entry that matched no surviving
  mutant is reported as **stale**: the mutant is now killed or the code changed. `--strict-ignore` turns that into
  exit 1.
- An ignored mutant is still run. If it is killed it counts as killed; if it survives it is reported as
  `equivalent` and left out of the score.

`--suggest-ignore` prints a ready-made entry for every survivor; fill in `reason` for the true equivalents and write
tests for the rest.

## Using it in CI

```yaml
# .github/workflows/mutation.yml
name: Mutation testing
on: [pull_request]
jobs:
  mutation:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0            # --since needs the base branch
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Mutation test the changed files
        run: >
          bundle exec mutaruby
          -t "bundle exec rspec --fail-fast"
          --since origin/${{ github.base_ref }}
          --fail-under 85 --strict-ignore
          --junit mutaruby.xml --json mutaruby.json
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: mutaruby
          path: mutaruby.*
```

For a large code base, split the work across machines with `--shard`:

```yaml
    strategy:
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      # ...
      - run: bundle exec mutaruby -t "bundle exec rspec --fail-fast" --shard ${{ matrix.shard }}/4 --json shard-${{ matrix.shard }}.json
```

Each shard reports its own score; to get the overall score, add up `counts` across the JSON files. Note that
`--fail-under` and stale-entry detection apply per shard.

## Output formats

**Human** (stdout): every survivor with its location, enclosing method, operator and a two-line diff, then the
summary.

**JSON** (`--json`): one document with `score`, `counts` (`mutants`, `killed`, `timeout`, `survived`, `equivalent`),
`complete` (true when no filter limited the run), the `files`, `baseline_seconds`, `timeout`, `stale_ignores`,
`warnings`, and one object per mutant:

```json
{
  "id": 7, "file": "lib/pricing.rb", "lineno": 14, "operator": "comparison", "method": "Pricing#discount",
  "line_text": "return 0 if total > 100", "occurrence": 1, "orig": ">", "repl": ">=", "change": "> => >=",
  "label": "comparison: > => >=", "status": "survived", "seconds": 0.412, "ignore_reason": null
}
```

`status` is `killed`, `timeout` (also a kill), `survived` or `equivalent`.

**JUnit XML** (`--junit`): one `testcase` per mutant. A survivor is a `failure` (with the diff), an equivalent mutant
is `skipped` (with the reason) and the score is a suite `property`. CI systems that read JUnit reports show the
survivors as failed tests.

## How it compares with mutant

[mutant](https://github.com/mbj/mutant) is the mature reference implementation of mutation testing for Ruby, and the
tool mutaruby is most often compared with. It is more capable: many more operators, semantic knowledge of Ruby's core
library, precise subject and test selection, and years of use on large code bases. It is distributed under its own
commercial licence (free for open source projects).

**mutaruby shares no code with mutant.** It is an independent, clean-room implementation, written from general,
publicly known ideas about mutation testing (operators, coverage-based test selection, equivalent-mutant handling),
and it is MIT-licensed. Its only runtime dependency is `parser`; `unparser`, an MIT-licensed gem, is an optional
extra for `--unparser`.

mutaruby aims to be **MIT-licensed and simple**:

- It works with **any test command** (rspec, minitest, rake, a Makefile target), because the oracle is just an exit
  status. With `--coverage` it also runs only the tests that reach each mutant, for Minitest and RSpec suites.
- It is small enough to read in an afternoon.
- It runs each mutant in a **separate process** in a **copy of the project**, so it cannot leave your working tree
  modified.

If you can use mutant, it will usually find more. If you need an MIT-licensed tool, or want something you can point
at any project with one command, mutaruby is for you.

## Design notes

**A fresh process per mutant.** Every run, the baseline and each mutant, is a new shell (`/bin/sh -c COMMAND`; `cmd.exe` on Windows) with its
own Ruby. Nothing loaded by one run can leak into the next. This matters more than it looks. When mutants are
evaluated inside one long-lived process, deleting a `require` cannot be detected because the library is already loaded,
and a deleted method or constant can quietly keep its old definition. Those mutants then "survive" and report test
gaps that do not exist. The cost is process start-up time per mutant; `--jobs` and a narrow test command are how you
pay it back.

**A sandbox, never the working tree.** At start-up each worker copies the project root (minus `.git`, `coverage` and
any `--copy-exclude`) into a temporary directory. A mutant is written into the worker's copy, the command runs there,
and the original bytes are written back before the next mutant. Your files are never opened for writing, so a crash,
a timeout or Ctrl-C cannot leave a mutant behind. If you run mutaruby under `bundle exec`, `BUNDLE_GEMFILE` is
pointed at the sandbox's Gemfile so that a `gemspec` line loads the sandbox's `lib/`, not your checkout's.

**Splicing at character offsets, with a self-check.** mutaruby does not regenerate source from the AST (that would
reformat the file and lose comments). Each mutant replaces exactly one source range, using the offsets that `parser`
reports for the node or token. Those offsets count **characters**, not bytes. Splicing by bytes moves every mutant
that comes after the first multi-byte character in a file (an accented letter in a comment is enough) onto the wrong
text. Before every splice, mutaruby checks that the slice it is about to replace is exactly the node's own source
text. If it is not, the run aborts rather than testing a mutant in the wrong place.

**The baseline must pass.** Before any mutant runs, the command runs once on the unmodified code. If it fails, every
mutant would be "killed" and the score would mean nothing, so mutaruby stops with exit status 2 and shows the tail of
the output. The baseline's duration also sets the default timeout.

**No run outlives its mutant.** Each run is the leader of its own process group. When the run times out, and also
when it finishes normally, whatever is left of the group (a hung test, a forked server, a parallel test worker) gets
`SIGTERM`, then `SIGKILL` if it is still there two seconds later. Nothing from one mutant's run can interfere with
the next one.

**Site keys instead of line numbers** for the ignore file; see [above](#equivalent-mutants-the-ignore-file).

## Windows notes

mutaruby works the same way on Windows, with these differences:

- **The shell is `cmd.exe`.** Quote with double quotes, not single quotes: `mutaruby -t "bundle exec rspec"` works in
  both shells, but `-t 'ruby -e "exit 1"'` is POSIX-only quoting. In `cmd.exe` the inner quotes have to be escaped
  (or put the command in a `.bat` file, or in a Rake task, and call that). Variables are written `%NAME%`, not
  `$NAME`.
- **Stopping a run.** Each run starts in a new process group. On timeout its whole process tree is stopped with
  `taskkill /T` (first without `/F`, then, after the same two-second grace period, with `/F`). Unlike on POSIX
  systems, processes that a run leaves behind after it exits normally are not stopped: Windows finds a tree through
  the parent process, which is gone by then, and its id may already belong to an unrelated process. Make test
  helpers that start servers stop them.
- **Sandboxes** are named `mr…` (shorter than `mutaruby-…`) under `%TEMP%`, because classic Windows paths are
  limited to 260 characters. For a deeply nested project, enable long paths or point `TMP`/`TEMP` at a short
  directory such as `C:\t`.
- **Locked files.** A process that is still exiting, or a virus scanner, can hold a file open for a moment. Writes
  into the sandbox and its removal are retried (10 times, 0.1 s apart) before mutaruby gives up.
- **Symlinks** in the project are copied as symlinks when Windows allows it (Developer Mode or the symlink
  privilege), and otherwise replaced by a copy of what they point to.
- **Line endings.** Files with CRLF (or mixed) line endings are mutated in place without changing their line endings.
  Sources are read as UTF-8 regardless of the console code page.

## Limitations

- On Windows, processes that a test run leaves running after it exits normally are not stopped (see
  [Windows notes](#windows-notes)).
- Per-test selection (`--coverage`) understands Minitest and RSpec; any other command runs in full for every mutant.
  Selection assumes the tests do not depend on each other's order or side effects.
- The parser grammar is chosen to match the running Ruby, up to the newest grammar the installed `parser` gem knows.
  Files that `parser` cannot read (for example syntax newer than it supports) are skipped with a warning.
- Mutants are syntactic. Some are equivalent by nature; that is what the ignore file is for.
- Files are copied into each worker's sandbox at start-up, so very large repositories should use `--copy-exclude`
  for directories the tests do not need.

## Contributing, security, licence

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). mutaruby is released under the
[MIT licence](LICENSE).
