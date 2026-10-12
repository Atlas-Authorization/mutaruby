# Security policy

## Supported versions

Security fixes are made for the latest released version of mutaruby.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/Atlas-Authorization/mutaruby/security/advisories/new)
rather than in a public issue. Include the version, how to reproduce the problem, and what impact you see. We aim to
acknowledge a report within a few working days and will keep you informed as we work on a fix.

## Security model

mutaruby runs the test command you give it, once on your unmodified code and once per mutant, with your user's
permissions. Mutants are arbitrary changes to your code, so the code that runs can behave differently from your real
code: a mutated condition can, for example, make a test hit a branch that deletes files or calls a network service
you normally only reach in production.

- Run mutaruby only on code and test commands you trust, and with the same isolation you would give the test suite
  (no production credentials in the environment, test databases only).
- Each run happens inside a temporary copy of the project, and mutaruby never writes to your working tree. That copy
  is a convenience, not a security boundary: the command can still reach anything your user can.
- Ignore files are parsed with `YAML.safe_load` (no custom classes, no aliases).
