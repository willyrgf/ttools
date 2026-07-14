# ttools

`ttools` means **tiny tools**: a small collection of focused command-line tools
published from `github:willyrgf/ttools`. The default Nix app is a generated
dispatcher for the initial `nix-cleanup` and `git-history` tools.

## Dispatcher

Run the tiny-tool catalog, list tools, or dispatch one tool:

```bash
nix run 'github:willyrgf/ttools'
nix run 'github:willyrgf/ttools' -- list
nix run 'github:willyrgf/ttools' -- nix-cleanup --help
nix run 'github:willyrgf/ttools' -- git-history --help
```

The `ttools` dispatcher consumes only the tool name. Every remaining argument,
standard input, output stream, signal, and exit status is passed directly to
that tool.
Tool names are lowercase kebab-case. `help`, `list`, `version`, and `default`
are reserved by the dispatcher.

Direct package outputs are available when the dispatcher closure is not wanted:

```bash
nix run 'github:willyrgf/ttools#nix-cleanup' -- --quick
nix run 'github:willyrgf/ttools#git-history' -- review --base origin/main
nix build 'github:willyrgf/ttools#default'
```

## `nix-cleanup`

`nix-cleanup` safely removes dead Nix store paths. It classifies candidates
against a dead-path snapshot, skips paths that are still alive, asks for
confirmation before deletion, and can run final garbage collection explicitly.

```text
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] --system
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] --older-than 30d
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] <flake-package>
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] /nix/store/path ...
nix-cleanup [--yes] [--jobs N] --gc-only
nix-cleanup --add-cron [<command-or-cron-entry>]
```

Important options:

- `--quick` performs one deletion pass, defaults to `--system` when no target
  is selected, and defaults to `--no-gc` unless `--gc` is explicit.
- `--yes` skips the deletion confirmation prompt.
- `--older-than <duration>` accepts values such as `30d` and filters dead
  paths by age.
- `--jobs <N>` controls parallel filtering and deletion workers.
- `--gc-only`, `--gc`, and `--no-gc` control garbage collection.
- `--add-cron` installs a root crontab entry. With no value it uses the
  documented daily cleanup command; plain commands are normalized to `@daily`.

Deletion and garbage collection require `sudo` and the host user's privilege
configuration. `--add-cron` also modifies root's crontab and requires `sudo`.
Help and validation paths do not delete store paths or change crontabs.
Runtime commands are supplied by the package wrapper; `sudo` remains an
explicit host capability because its behavior cannot be safely bundled.

Examples:

```bash
nix run . -- nix-cleanup --quick --yes
nix run . -- nix-cleanup --older-than 30d --quick
nix run . -- nix-cleanup --system --jobs 16 --yes
nix run . -- nix-cleanup --quick --gc --yes
nix run . -- nix-cleanup --gc-only
nix run . -- nix-cleanup --add-cron
```

Use `--` to terminate option parsing when a positional operand must begin with
a hyphen. Long options use the canonical `--option <value>` form; duplicate
`--option=value` forms and the old `help` and `-y` aliases are not supported.

## `git-history`

`git-history` reviews commits on the current branch and, only when explicitly
requested, rewrites selected commit messages. The selected range is
`merge-base(<base>, HEAD)..HEAD`; pass an explicit `--base` for reproducible
work.

```bash
nix run . -- git-history review --base origin/main
nix run . -- git-history fix-messages --base origin/main --max-subject-length 72
nix run . -- git-history add-prefix 'cleanup: ' --base origin/main
```

Commands:

- `review` is read-only. It reports empty, multi-line, trailer/author, and
  overlong message violations.
- `fix-messages` normalizes selected subjects and can use
  `--truncate-long` with `--max-subject-length <N>`.
- `add-prefix <prefix>` adds a literal subject prefix and is idempotent.

The two rewriting commands require a checked-out branch with no staged or
unstaged tracked changes. Before moving the branch, they create a backup branch
named like `backup/git-history-<branch>-<timestamp>`. They preserve each final
tree, parent topology, author and committer identities, and author and
committer dates. Commit IDs change when messages or rewritten parents change.
Signed commits and commits with unsupported extra headers are refused.

Every tool supports `-h`, `--help`, `--` as the end-of-options marker, lowercase
kebab-case long options, side-effect-free help/validation paths, and nonzero
status for validation or operational failures. Normal results go to stdout;
diagnostics and progress go to stderr.

## Development and validation

The public collection is named `ttools`; its internal `tools/<name>` directories
hold the individual tiny tools. Each directory must contain its source,
`package.nix`, `check.nix`, and local tests. Adding a tool does not require
editing a root command registry.

Useful local commands:

```bash
bash -n tools/nix-cleanup/nix-cleanup.sh
bash -n tools/git-history/git-history.sh
nix build .#nix-cleanup
nix build .#git-history
nix build .#default
nix run . -- --help
nix run . -- list
nix run . -- git-history --help
nix run . -- nix-cleanup --help
nix flake check --print-build-logs --show-trace
nix develop
```

The root checks run every discovered tool check plus Bash syntax, shellcheck,
shfmt, actionlint, statix, deadnix, and ttools dispatcher smoke tests. Tool
checks use temporary fixtures; do not run cleanup against a real store or
rewrite this repository's history while developing.

The pinned `flake.lock` is the dependency source of truth. Update it only as an
intentional dependency maintenance change, then rerun the complete flake check.
