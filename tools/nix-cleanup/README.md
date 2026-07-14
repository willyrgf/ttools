# nix-cleanup

Safely remove dead Nix store paths and optionally run garbage collection.

## Usage

```text
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] --system
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] --older-than 30d
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] <flake-package>
nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] /nix/store/path ...
nix-cleanup [--yes] [--jobs N] --gc-only
nix-cleanup --add-cron [<command-or-cron-entry>]
nix-cleanup -h | --help
```

Run through the dispatcher:

```bash
nix run 'github:willyrgf/ttools' -- nix-cleanup --quick --yes
```

## Options

- `--yes` skips the deletion confirmation prompt.
- `--system` discovers candidates directly under `/nix/store`.
- `--older-than <duration>` filters dead paths by age, such as `30d`.
- `--quick` performs one deletion pass, defaults to `--system` when no target
  is selected, and defaults to `--no-gc` unless `--gc` is explicit.
- `--jobs <N>` controls parallel filtering and deletion workers.
- `--gc-only`, `--gc`, and `--no-gc` control garbage collection.
- `--add-cron [<command-or-cron-entry>]` adds a root crontab entry. Plain
  commands are normalized to `@daily`; no value uses the default cleanup
  command.

Use `--` to end option parsing. Long options use the canonical
`--option <value>` form; `--option=value`, `help`, and `-y` are not supported.

## Safety

Candidates are classified against a dead-path snapshot before deletion. Paths
that are still alive are skipped. Deletion, garbage collection, and crontab
changes require `sudo` and the host user's privilege configuration.

Help and argument validation do not delete store paths or change crontabs.
Normal results go to stdout; diagnostics and progress go to stderr.

Examples:

```bash
nix run . -- nix-cleanup --older-than 30d --quick
nix run . -- nix-cleanup --system --jobs 16 --yes
nix run . -- nix-cleanup --quick --gc --yes
nix run . -- nix-cleanup --gc-only
nix run . -- nix-cleanup --add-cron
```
