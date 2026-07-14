# Repository Guidelines

## Project structure

The repository is a convention-driven collection of self-contained tools:

- `flake.nix` discovers and packages immediate `tools/<name>` directories,
  generates the `tools` dispatcher, and composes quality checks.
- `tools/<name>/<source>` contains one public tool and its implementation.
- `tools/<name>/package.nix` returns the executable package for that tool.
- `tools/<name>/check.nix` returns the deterministic local quality check.
- `tools/<name>/tests/` contains tool-specific Bats suites and fixtures.
- `README.md` documents user-facing commands and safety boundaries.
- `docs/code-quality.md` is the repository quality policy.
- `RFC_REPOSITION_REPO.md` and `IMPL_PLAN_RFC_REPOSITION_REPO.md` define the
  target architecture and implementation requirements.
- `.github/workflows/nix-checks.yml` runs the flake checks and disposable
  cleanup integration test.
- `flake.lock` pins flake inputs and changes only during intentional updates.

Do not add root-level tool copies, a handwritten command registry, compatibility
wrappers, or a shared parser/runtime. Keep new logic and tests inside the tool
directory that owns them.

## Build, test, and development commands

Run the generated dispatcher and direct packages with:

```bash
nix run . -- --help
nix run . -- list
nix run . -- nix-cleanup --help
nix run . -- git-history --help
nix build .#nix-cleanup
nix build .#git-history
nix build .#default
nix flake check --print-build-logs --show-trace
nix develop
```

Minimum source checks for Bash changes are:

```bash
bash -n tools/nix-cleanup/nix-cleanup.sh
bash -n tools/git-history/git-history.sh
git diff --check
```

Prefer help, invalid-argument, fixture, and package checks during development.
Run cleanup deletion only against the disposable CI-style fixture. Never use
the test suites to rewrite this repository's history.

## Tool package contract

Each immediate child of `tools/` is a lowercase kebab-case public tool and must
contain both `package.nix` and `check.nix`. The package function has this
contract:

```nix
{ pkgs, lib, toolName, flakeCommit ? "unknown" }:
```

It returns one executable derivation with a concise `meta.description` and
`meta.mainProgram`. Runtime dependencies belong to that package. A tool must
not rely on ambient language runtimes or an undeclared host command. A local
`check.nix` owns test-only dependencies and returns one deterministic check.

`sudo` is an explicit exception: cleanup privilege behavior depends on the
host user's security configuration and must remain documented rather than
hidden behind a fallback.

## CLI and safety conventions

Every tool owns its parser and safety behavior. Tools should support `-h` and
`--help`, lowercase kebab-case commands/options, `--` as the end-of-options
marker, side-effect-free help and validation, zero for successful no-ops, and
nonzero status for validation or operational failures. Use stdout for normal
results and stderr for errors, diagnostics, and progress.

Use canonical `--option <value>` syntax. Do not add generic flags or preserve
undocumented aliases merely for compatibility. Keep domain-specific options in
the tool that understands them.

`nix-cleanup` requires explicit confirmation unless `--yes` is supplied; it
must classify paths as dead before deletion, skip alive paths, and document
garbage-collection and `sudo` behavior. `git-history review` is read-only;
`fix-messages` and `add-prefix` rewrite selected history only after validation,
create a backup branch before moving the current branch, and preserve trees,
topology, and author/committer metadata.

## Style

- Bash uses `#!/usr/bin/env bash` in source files, two-space indentation, and
  quoted expansions.
- Bash function names use the repository's established underscore-prefixed
  snake_case style where applicable.
- Use `local` inside functions and keep output concise and actionable.
- Keep runtime dependencies in `package.nix`; keep test-only dependencies in
  `check.nix`.
- Format Bash with `shfmt -i 2 -ci -sr` and pass shellcheck before committing.
- Keep Nix expressions statix/deadnix-clean and workflows actionlint-clean.

## Commits and pull requests

Use concise, imperative, lowercase, one-line commit subjects. Do not add a
commit body, author/co-author/review trailer, or other metadata trailer. Keep
each implementation commit focused and leave the flake evaluable.

Pull requests should state:

- what behavior or structure changed and why;
- the exact validation commands and their results; and
- any safety impact, especially deletion, garbage collection, history rewrite,
  root crontab changes, or `sudo` usage.
