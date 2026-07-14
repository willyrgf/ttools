# Implementation plan: reposition the repository as `tools`

- Source of truth: [RFC_REPOSITION_REPO.md](RFC_REPOSITION_REPO.md)
- Status: implementation complete; final verification recorded
- Scope: migrate this repository to the RFC's final two-tool architecture

This document is an execution plan for the engineer-agent. Work through the
phases in order, keep the worktree understandable after every commit, and
update this plan only when an implementation decision changes.

## Non-negotiable rules

These rules take precedence over older repository behavior or any transitional
implementation choice:

1. Simplicity is king. Minimize concepts, code paths, public types, duplicated
   responsibilities, and places future changes must touch. Reduce lines when
   that does not make the code cryptic.
2. Do not maintain backward compatibility. Breaking the old default app,
   paths, flags, environment variables, and documentation is allowed.
3. Do not add fallbacks, compatibility wrappers, aliases, legacy modes, or
   hidden copies of old code. Move the source once and delete the old location.
   Recover old code from Git history only when necessary.
4. Commit progressively. Each commit must leave the flake evaluable and must
   have one focused responsibility.
5. Before implementation, read `docs/code-quality.md` completely. That file is
   not present in the current checkout or its Git history; obtain it or add it
   explicitly before claiming compliance. Do not invent a silent substitute.
6. Commit subjects are concise, lowercase, one-line messages. Do not add a
   commit body or author, co-author, review, or other trailer metadata.
7. If architecture/design decisions are unclear, spawn an architect-agent
   and pass these rules along.

## Current baseline

The repository currently contains one packaged root-level tool:

- `nix-cleanup.sh` and `tests/cli.bats` are at the repository root.
- `flake.nix` packages the root script, exposes `nix-cleanup` as the default
  app, and still defines the deprecated `defaultPackage` alias.
- `README.md`, `AGENTS.md`, and CI describe only `nix-cleanup`.
- `git-history.sh` is present at the root but has no package or test contract.
- `RFC_REPOSITION_REPO.md` defines the target dispatcher, tool layout, CLI
  conventions, mandatory `package.nix`/`check.nix` files, and no compatibility
  wrapper.

The implementation must not leave a second root-level copy of either script or
of the existing tests.

## Target architecture

The final repository should have this shape:

```text
flake.nix
flake.lock
README.md
AGENTS.md
RFC_REPOSITION_REPO.md
IMPL_PLAN_RFC_REPOSITION_REPO.md
docs/
  code-quality.md                 Required project quality guidance.
tools/
  nix-cleanup/
    nix-cleanup.sh
    package.nix
    check.nix
    tests/
      cli.bats
  git-history/
    git-history.sh
    package.nix
    check.nix
    tests/
      cli.bats
      rewrite.bats
```

There is no tracked dispatcher template, root `tests/` directory, root
`nix-cleanup.sh`, root `git-history.sh`, compatibility wrapper, legacy mode, or
hand-maintained tool registry.

### Package boundary

Each immediate child of `tools/` is one public tool and must contain both
`package.nix` and `check.nix`.

`package.nix` follows the RFC contract:

```nix
{ pkgs, lib, toolName, flakeCommit ? "unknown" }:
```

It returns one executable derivation with `meta.description` and
`meta.mainProgram`. Runtime inputs belong to that package. Do not create a
shared shell runtime, parser, registry, or cross-language build framework.

`check.nix` receives the package derivation and returns one deterministic check
derivation. It owns test-specific dependencies and runs tests located in the
same tool directory. This keeps new tools self-contained while ensuring every
discovered tool has CI coverage.

Use `pkgs.writeShellApplication` or the smallest equivalent Nix wrapper for
the Bash tools. It should provide a pinned runtime `PATH` from the tool's own
package. `nix-cleanup` keeps its flake-commit display and its existing runtime
behavior. `git-history` packages Bash, Git, and the text/file utilities it
invokes. `sudo` remains an explicit host privilege capability because its
behavior depends on the host's user/security configuration; do not replace it
with a hidden fallback.

### Flake and dispatcher

Keep `flake.nix` responsible only for:

- discovering and sorting immediate tool directories with `builtins.readDir`;
- validating the required package and check files and reserved tool names;
- importing each package and check derivation;
- generating the dispatcher and its sorted catalog;
- composing package, app, check, and development-shell outputs; and
- defining repository-wide quality checks.

Generate the dispatcher directly in `flake.nix` with
`pkgs.writeShellScriptBin`. Its generated data includes each tool's description
and absolute executable path. It must:

- show catalog/usage for no arguments, `help`, or `--help` as defined by the
  RFC;
- list tools in deterministic sorted order for `list`;
- reject reserved/unknown tool names with a concise stderr error and nonzero
  status; and
- dispatch with `exec "$program" "$@"` after consuming only the tool name.

The dispatcher must preserve arguments, stdin, stdout, stderr, signals, and the
selected tool's exit status. It must not inspect or reinterpret tool-specific
flags, and it must never invoke `nix run` at runtime.

Expose:

- `packages.<tool>` for every discovered tool;
- `packages.default` for the generated `tools` executable; and
- `apps.default` pointing to the generated `tools` executable.

Remove the deprecated `defaultPackage` output. The direct `#nix-cleanup` and
`#git-history` package outputs are canonical per-tool entrypoints, not legacy
compatibility paths.

## CLI implementation rules

Each tool owns its parser and safety behavior. Apply the RFC's conventions
without creating a shared parser. These are final-state requirements; the
behavior changes are intentionally applied in the late conformance phase after
the package, dispatcher, fixture, and quality foundations are working.

Every tool must:

- support `-h` and `--help`;
- use lowercase kebab-case for commands and long options;
- accept `--` as the end-of-options marker;
- keep help and validation paths side-effect free;
- return zero for success, including a valid no-op; and
- return nonzero for validation or operational failures.

Use stdout for normal results and stderr for errors, diagnostics, and progress.
The dispatcher must not alter this routing.

For the initial tools:

- `git-history` requires an explicit `review`, `fix-messages`, or `add-prefix`
  subcommand. Remove its implicit default command and undocumented
  `--review`/`--fix` aliases.
- Keep the canonical value syntax as `--option <value>`. Remove duplicate
  `--option=value` branches unless a concrete tool need justifies them.
- Keep only the universal `-h` short alias unless a domain-specific alias is
  clearly documented and useful. In particular, remove the old `help` and
  `-y` compatibility aliases from `nix-cleanup`.
- Keep domain-specific options such as `--base`, `--older-than`, `--jobs`, and
  `--no-gc` local to the tool that understands them.
- Document mutation boundaries. `git-history review` is read-only;
  `fix-messages` and `add-prefix` rewrite selected history and create a backup
  branch. `nix-cleanup` documents confirmation, deletion, GC, and privilege
  behavior.

Do not add generic `--force`, `--quick`, `--verbose`, `--dry-run`, or
`--version` flags merely for symmetry. Add a flag only when its semantics are
clear and useful for that tool.

## Implementation phases

### Phase 0: quality and documentation preflight

- Read `docs/code-quality.md` completely once it is available.
- Reconcile any additional quality requirements with this plan before changing
  source files.
- Keep the RFC's no-compatibility wording, mandatory `check.nix` convention,
  and explicit `flakeCommit` package argument in sync with this plan.
- Do not update `flake.lock` unless a dependency change is intentional and
  necessary.

Suggested commit when only these documents change:

```text
clarify tools migration constraints
```

### Phase 1: restructure tools into self-contained packages

Move files with `git mv` and delete the old locations in the same change:

- `nix-cleanup.sh` → `tools/nix-cleanup/nix-cleanup.sh`;
- `tests/cli.bats` → `tools/nix-cleanup/tests/cli.bats`; and
- `git-history.sh` → `tools/git-history/git-history.sh`.

Add `package.nix` and `check.nix` to both tool directories. Keep tool-specific
runtime and test dependencies inside those files. Add no root-level copies and
no compatibility launchers.

The `nix-cleanup` package must preserve its actual cleanup behavior, including
the flake-commit display and pinned ordinary runtime commands. The
`git-history` package must expose the executable as `git-history`.

Suggested commit:

```text
restructure tools into self-contained packages
```

Verification before committing:

```bash
bash -n tools/nix-cleanup/nix-cleanup.sh
bash -n tools/git-history/git-history.sh
git diff --check
```

### Phase 2: add generated dispatcher and dynamic flake outputs

Replace the single-tool flake wiring with convention-driven discovery:

- enumerate only immediate directories under `tools/`;
- sort tool names;
- fail evaluation when a tool lacks `package.nix` or `check.nix`;
- reject invalid or reserved names;
- import packages with `flakeCommit` available;
- import each tool's `check.nix` with its package derivation;
- generate the catalog and dispatch cases from the resulting attributes; and
- compose packages, app, checks, and shells without a manual tool list.

The initial dispatcher must work with both tools before this phase is complete.
Its `list` output must be deterministic, and its dispatch path must use `exec`.

Suggested commit:

```text
add generated tools dispatcher
```

Verification before committing:

```bash
nix build .#nix-cleanup
nix build .#git-history
nix build .#default
nix run . -- --help
nix run . -- list
nix run . -- nix-cleanup --help
nix run . -- git-history --help
```

### Phase 3: add fixture-based tool checks

`tools/nix-cleanup/check.nix` should run the moved Bats suite against the
packaged cleanup executable. Preserve mocks for `find`, `sudo`, and `crontab`,
and keep destructive operations confined to fixtures.

Add `tools/git-history/tests/cli.bats` for help and validation, and
`tools/git-history/tests/rewrite.bats` for temporary Git repositories. The
history fixtures must verify:

- explicit `--base` handling and branch-range selection;
- review detection of empty, multi-line, trailer, and overlong messages;
- successful message normalization without changing trees or metadata;
- subject-prefix application and idempotence;
- preservation of parent topology and author/committer identities and dates;
- creation of a backup branch before the rewritten branch moves; and
- no mutation of the repository when validation fails or no messages change.

Use deterministic identities, timestamps, and explicit base revisions in the
fixtures. Never rewrite the working repository's history in a test.

Suggested commit:

```text
add history rewrite fixtures
```

### Phase 4: consolidate repository quality checks

Make the root flake compose per-tool checks plus repository-wide checks:

- syntax-check every Bash source under `tools/`;
- shellcheck and shfmt every Bash source under `tools/`;
- run each discovered `check.nix` derivation;
- keep `actionlint`, `statix`, and `deadnix` checks;
- smoke-test the generated dispatcher with an empty ambient `PATH`; and
- keep runtime dependencies in package wrappers rather than in a root runtime
  registry.

Update development shells to provide quality tooling without a
tool-specific global test variable. A developer can invoke a tool through its
package output or run its local check directly.

Suggested commit:

```text
consolidate repository quality checks
```

### Phase 5: apply initial tool conformance

Do this after packaging, dispatch, fixture coverage, and repository-wide checks
are working. The goal is to turn the initial tools into precise examples for
future tools, without introducing shared parsing code.

For `nix-cleanup`:

- make help output use the packaged executable name;
- route errors, diagnostics, and progress to stderr while keeping normal
  results on stdout;
- keep only `-h` and `--help` as help forms, removing the positional `help`
  alias;
- remove the `-y` alias and document `--yes` as the safety flag;
- keep the canonical `--option <value>` form and remove duplicate
  `--option=value` parsing branches; and
- add tests for `--`, invalid arguments, exit status, and side-effect-free
  validation.

For `git-history`:

- require an explicit `review`, `fix-messages`, or `add-prefix` subcommand;
- remove the implicit default `review` command and `--review`/`--fix` aliases;
- keep the canonical `--option <value>` form and remove duplicate
  `--option=value` parsing branches;
- make help output use the packaged executable name;
- route errors, diagnostics, and progress to stderr while keeping review and
  successful command results on stdout; and
- add tests for `-h`, `--help`, `--`, invalid arguments, exit status, and
  mutation-free validation.

Do not change domain semantics while normalizing the interfaces. Do not add
generic flags merely for symmetry, and do not make cleanup tests touch a real
store or history tests touch this repository.

Suggested commit:

```text
normalize initial tool cli contracts
```

### Phase 6: rewrite documentation and CI

Rewrite `README.md` around the `tools` dispatcher:

- catalog and `list` behavior;
- direct package outputs;
- `nix-cleanup` usage and safety;
- `git-history` usage, explicit bases, and rewrite warnings;
- shared CLI conventions; and
- development and validation commands.

Update `AGENTS.md` for the `tools/<name>` structure, package/check contract,
new commands, and safety rules. Remove stale root-script instructions and old
default-app examples.

Update CI to:

- run `nix flake check --print-build-logs --show-trace`;
- smoke-test the root dispatcher and both tool help paths; and
- build/use `.#nix-cleanup` only against a disposable store fixture for the
  deletion integration test.

Do not add a workflow for compatibility testing of the old app or old paths.

Suggested commit:

```text
update documentation and ci
```

## Verification matrix

Run the smallest relevant checks after each phase and the complete set before
handoff:

```bash
git diff --check
bash -n tools/nix-cleanup/nix-cleanup.sh
bash -n tools/git-history/git-history.sh
nix build .#nix-cleanup
nix build .#git-history
nix build .#default
nix run . -- --help
nix run . -- list
nix run . -- nix-cleanup --help
nix run . -- git-history --help
nix flake check --print-build-logs --show-trace
```

Also verify nonzero status and stderr diagnostics for unknown dispatcher tools
and invalid tool arguments. Use a temporary fixture repository for:

```bash
nix run . -- git-history review --base <fixture-base>
```

The final checks must not delete real Nix store paths or rewrite this
repository's history.

## Deletion and stale-reference audit

Before completion, confirm that these are gone:

- root `nix-cleanup.sh`;
- root `git-history.sh`;
- root `tests/`;
- `defaultPackage` in `flake.nix`;
- old single-tool default-app wiring;
- compatibility wrappers, legacy modes, and fallback dispatch paths; and
- stale README, AGENTS, CI, or example references to the old default app.

Confirm that these remain intentionally available:

- `packages.nix-cleanup`;
- `packages.git-history`;
- `packages.default` for `tools`; and
- `apps.default` for `tools`.

## Definition of done

The implementation is complete only when:

- the final tree matches the target architecture;
- adding a tool requires only its own directory and no root command registry;
- the root dispatcher lists both tools in sorted order and faithfully forwards
  arguments, streams, signals, and exit status;
- both packages run with their declared runtime dependencies;
- every tool has a local `check.nix` and deterministic tests;
- CLI conventions and mutation safety are documented;
- CI exercises the dispatcher and disposable cleanup fixture;
- no backward-compatibility code or stale root layout remains; and
- every implementation commit is focused, lowercase, one line, and trailer-free.
