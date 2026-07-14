# RFC: Rebrand the repository as `ttools`

- Status: Implemented
- Date: 2026-07-14

## Summary

Reposition the current `nix-cleanup` repository as `ttools`—tiny tools: a small
collection of focused utilities published from `github:willyrgf/ttools`.

The repository has one public entrypoint. The default Nix app is a dispatcher
named `ttools`, initially exposing `nix-cleanup` and `git-history`:

```bash
nix run 'github:willyrgf/ttools'
nix run 'github:willyrgf/ttools' -- list
nix run 'github:willyrgf/ttools' -- nix-cleanup --quick
nix run 'github:willyrgf/ttools' -- <tool-name> [args...]
```

The flake discovers tools from the filesystem, packages them independently,
and generates the dispatcher from the resulting derivations. Adding a tool
should not require editing a command list or a manually maintained registry.

## Goals

- Provide one memorable invocation for the whole repository.
- Make adding a tool a local, self-contained change.
- Support Bash, Python, Go, Rust, and other languages without a shared runtime.
- Keep each tool's dependencies, help text, tests, and safety behavior local.
- Make the root command able to list the available tools automatically.
- Preserve direct Nix package outputs for users who need one tool specifically.
- Include both system cleanup and Git history maintenance without coupling
  their implementations or runtime dependencies.
- Keep the flake and repository structure small enough to understand at a glance.

## Non-goals

- A runtime plugin system.
- A cross-language build framework.
- A task runner or replacement for Nix packaging conventions.
- Automatic discovery outside the dedicated `tools/` directory.
- Independent release/versioning machinery for every tool.
- A dispatcher that invokes another `nix run` command at runtime.

## Command contract

The generated executable is `ttools`.

```text
ttools                         Show the catalog and usage.
ttools list                    List available tools.
ttools --help                 Show dispatcher help.
ttools <tool-name> [args...]  Execute one tool and pass arguments through.
```

The initial catalog is:

- `nix-cleanup`: safely remove dead Nix store paths and optionally run garbage
  collection.
- `git-history`: review commits on the current branch and, when explicitly
  requested, normalize commit messages or add a subject prefix.

`git-history review` is read-only. Its `fix-messages` and `add-prefix`
commands rewrite selected history, create a backup branch before moving the
current branch, and preserve the final tree, commit topology, and author and
committer metadata.

The dispatcher owns only its first argument. Once a tool name is selected, all
remaining arguments, standard input, standard output, standard error, and the
tool's exit status are passed through unchanged.

Tool names use lowercase kebab-case. The names `help`, `list`, `version`, and
`default` are reserved by the dispatcher and cannot be used for tools.

Every tool should provide its own `--help` behavior. The root catalog should
remain short; detailed behavior belongs to the selected tool.

## CLI conventions and recommended practices

The repository should normalize the user experience, not require every tool to
use the same parser or command structure. These conventions are guidance for
new tools and documentation, not behavior that the dispatcher or flake must
enforce.

### Required conventions

Every tool should:

- support `-h` and `--help`;
- use lowercase kebab-case for commands and long options;
- accept `--` to terminate options;
- print normal results to standard output and diagnostics or progress to
  standard error;
- return zero for success, including a valid no-op;
- return nonzero for argument-validation or operational failures; and
- keep help and invalid-argument paths free of side effects.

The dispatcher must preserve the selected tool's exit status.

### Recommended conventions

Use this general shape where it fits:

```text
tool [subcommand] [options] [operands]
```

Subcommands are appropriate when a tool has multiple distinct actions. They
should not be introduced merely to make every tool look identical. For
example, the initial tools can use:

```text
git-history review [options]
git-history fix-messages [options]
nix-cleanup [options] <target>
```

For options:

- use `--option <value>` for values;
- use boolean flags such as `--quick`, `--yes`, and `--truncate-long`;
- use `--no-<feature>` for explicit negation;
- reserve short aliases primarily for universal options such as `-h`; and
- avoid vague names such as `--force` or `--quick` unless their meaning is
  clearly defined for that tool.

Prefer explicit modes and targets over surprising defaults. A tool may provide
convenient defaults, but its help text should state them and show how to opt
out.

Mutation-capable tools should document:

- whether the default behavior is read-only;
- whether a dry-run or review mode exists;
- what `--yes` changes, if supported;
- what backup or recovery mechanism exists; and
- which objects, files, commits, or paths may be changed.

For this repository, `git-history` should make clear that `review` is
read-only, while `fix-messages` and `add-prefix` rewrite history and create a
backup branch. `nix-cleanup` should similarly document its confirmation,
deletion, garbage-collection, and privilege behavior.

### Tool-specific freedom

Options should remain tool-specific when their semantics are domain-specific.
For example, `git-history --base` and `--max-subject-length` need not be shared
with `nix-cleanup`, just as `nix-cleanup --jobs`, `--older-than`, and `--no-gc`
need not appear on other tools. The common convention is about semantics and
documentation, not about making every tool expose the same flags.

## Initial tool conformance

Moving the existing scripts into `tools/` is not sufficient. After the package
and dispatcher architecture is working, the migration should apply the shared
conventions to the initial tools and make them the reference implementations
for future tools. This is a deliberate late migration phase so packaging and
CLI conformance can be reviewed separately.

For `nix-cleanup`, the conformance work should:

- make help output use the packaged executable name;
- send errors, diagnostics, and progress to standard error while keeping normal
  results on standard output;
- keep `-h` and `--help` as the help forms and remove the positional `help`
  alias;
- remove the `-y` alias so `--yes` is the documented safety flag;
- use the canonical `--option <value>` form and remove duplicate
  `--option=value` parsing branches; and
- test `--`, invalid arguments, exit status, and side-effect-free validation.

For `git-history`, the conformance work should:

- require an explicit `review`, `fix-messages`, or `add-prefix` subcommand;
- remove the implicit default `review` command and undocumented `--review` and
  `--fix` aliases;
- use the canonical `--option <value>` form and remove duplicate
  `--option=value` parsing branches;
- make help output use the packaged executable name;
- send errors, diagnostics, and progress to standard error while keeping review
  results and successful command results on standard output; and
- test `-h`, `--help`, `--`, invalid arguments, exit status, and mutation-free
  validation.

The conformance phase must not introduce a shared parser or make the
dispatcher interpret tool-specific flags. It must update each tool's local
help, tests, and safety documentation together. No generic flags should be
added merely for symmetry.

## Repository layout

```text
flake.nix
flake.lock
README.md
tools/
  nix-cleanup/
    nix-cleanup.sh              Tool source.
    README.md                   Usage and safety documentation.
    package.nix                  Tool derivation.
    check.nix                   Tool quality check derivation.
    tests/
      cli.bats                   Tool-specific tests.
  git-history/
    git-history.sh               Tool source.
    README.md                    Usage and safety documentation.
    package.nix                  Tool derivation.
    check.nix                   Tool quality check derivation.
    tests/
      cli.bats                   Help and argument-validation tests.
      rewrite.bats               Fixture-based history rewrite tests.
  another-tool/
    main.py
    README.md
    package.nix
    check.nix
    tests/
```

Each immediate child directory of `tools/` is one tool. A directory is valid
only when it contains `README.md`, `package.nix`, and `check.nix`. The local
README owns the tool's usage and safety documentation; the root README remains
a compact index. Shared repository code, if it becomes necessary, belongs
outside `tools/<name>` and should be introduced only after repetition is
demonstrated.

## Tool package contract

Each `tools/<name>/package.nix` receives the package set, library, and
filesystem-derived tool name, then returns one executable derivation:

```nix
{ pkgs, lib, toolName, flakeCommit ? "unknown" }:

pkgs.someBuilder {
  pname = toolName;
  # tool-specific source and build instructions

  meta = {
    description = "One-line description used by the root catalog.";
    mainProgram = toolName;
  };
}
```

The contract is intentionally narrow:

- `meta.description` is a concise, single-line catalog description.
- `meta.mainProgram` identifies the executable to dispatch.
- `README.md` documents the tool's usage, options, output, and safety boundary.
- The derivation must produce an executable program.
- The package owns all runtime dependencies; it must not rely on ambient host
  language runtimes or tools.
- One directory represents one public command. Tools that expose several
  unrelated commands should be split into separate directories.
- `check.nix` returns the deterministic quality check for the tool and owns its
  test-specific dependencies.

Privileged system capabilities such as `sudo` may remain host-provided when
they depend on the host's user and security configuration. This is an explicit
exception to the ordinary runtime dependency rule and must be documented by
the affected tool.

The existing `nix-cleanup` runtime wrapper, pinned `PATH`, and flake-commit
display remain specific to `tools/nix-cleanup/package.nix`. They should not
become global behavior of the repository dispatcher.

`tools/git-history/package.nix` should expose the source as `git-history` and
bundle Bash, Git, and the standard text/file utilities it invokes (`awk`,
`sed`, `mktemp`, and related core utilities). The tool must continue to run
against the caller's Git worktree, while its executable and runtime tools come
from its Nix package rather than the ambient `PATH`.

## Flake discovery and generated dispatcher

The flake should use `builtins.readDir` to enumerate the immediate children of
`./tools`, retain directories, validate that each contains `README.md`,
`package.nix`, and `check.nix`, and sort the names for deterministic output.

Conceptually:

```nix
toolNames = sortedImmediateDirectories ./tools;

toolPackages = lib.genAttrs toolNames (toolName:
  import (./tools + "/${toolName}/package.nix") {
    inherit pkgs lib toolName flakeCommit;
  });

toolChecks = lib.genAttrs toolNames (toolName:
  import (./tools + "/${toolName}/check.nix") {
    inherit pkgs lib toolName;
    package = toolPackages.${toolName};
  });
```

The flake then derives catalog metadata and executable paths from
`toolPackages`:

```nix
toolInfo = lib.mapAttrs (toolName: package: {
  description = package.meta.description;
  program = lib.getExe package;
}) toolPackages;
```

The default `ttools` executable is generated directly in the flake from
`toolInfo`. It contains:

- a sorted catalog of names and descriptions;
- a dispatch case for each tool name;
- the absolute Nix store path of each tool's main executable.

This is discovery at flake evaluation/build time, not runtime introspection of
Nix derivations. The executable receives a complete generated catalog and does
not need to invoke Nix to discover tools.

The outputs should look conceptually like this:

```nix
packages = toolPackages // {
  default = ttoolsEntrypoint;
};

apps.default = {
  type = "app";
  program = "${ttoolsEntrypoint}/bin/ttools";
};
```

There is no handwritten list of tools in the dispatcher, no tracked dispatcher
template, and no separate registry to keep synchronized with the filesystem.

## Closure-size tradeoff

Because the generated dispatcher references every tool executable, the default
entrypoint's Nix closure includes every packaged tool. This is the simplest
implementation and is appropriate while the collection remains genuinely
small.

The flake should also expose individual packages:

```bash
nix run 'github:willyrgf/ttools#nix-cleanup' -- --quick
nix run 'github:willyrgf/ttools#git-history' -- review --base origin/main
```

That provides a smaller escape hatch for a tool with a large language runtime.
If the default closure later becomes a real problem, measure it first and
revisit the packaging model. A runtime dispatcher that recursively invokes
`nix run` is deliberately out of scope because it introduces extra latency,
revision ambiguity, and dependence on a second Nix evaluation.

## Testing and quality checks

The existing `nix-cleanup` tests move with the tool. Every discovered tool
provides a deterministic `check.nix` next to its package, with tool-specific
tests kept near that tool. The root flake composes those checks with the
repository-wide quality checks.

At minimum, repository validation should cover:

```bash
bash -n <tool source>
nix run . -- --help
nix run . -- list
nix run . -- <tool-name> --help
nix flake check --print-build-logs --show-trace
```

For the initial tools, this includes non-destructive smoke and argument checks
for both `nix-cleanup` and `git-history`, plus:

```bash
bash -n tools/git-history/git-history.sh
nix run . -- git-history --help
nix run . -- git-history review --base <rev>
```

`git-history` rewrite tests must create temporary Git repositories and use an
explicit base revision. They should verify message validation, prefix
idempotence, preservation of trees/topology/identities, and creation of the
backup branch without rewriting this repository's history. Destructive or
history-changing tools must use mocks or fixtures for tests. The dispatcher
itself must not add or reinterpret tool-specific safety flags such as
`nix-cleanup --yes`.

## Migration plan

1. Create `tools/nix-cleanup/` and move its source, package logic, and tests
   together.
2. Create `tools/git-history/` and move `git-history.sh`, its package logic,
   and fixture-based tests together.
3. Replace the current single-tool flake wiring with convention-driven tool
   discovery and generated dispatch.
4. Add the default `ttools` app, package outputs, and deterministic checks for
   discovered tools.
5. Apply the initial-tool conformance changes to both CLIs and update their
   tests to make the conventions executable examples.
6. Keep the root README as a compact index, add a usage/safety README to each
   tool, and update AGENTS guidance, CI workflow, development shells, and
   examples to describe the final interfaces.
7. Validate the local commands before renaming the GitHub repository to
   `ttools`.
8. Add future utilities as new `tools/<name>` directories that follow the
   package, check, CLI, and safety conventions.

The new canonical cleanup command is:

```bash
nix run 'github:willyrgf/ttools' -- nix-cleanup --older-than 30d
```

The initial Git history commands are:

```bash
nix run 'github:willyrgf/ttools' -- git-history review --base origin/main
nix run 'github:willyrgf/ttools' -- git-history fix-messages --base origin/main --max-subject-length 72
nix run 'github:willyrgf/ttools' -- git-history add-prefix 'cleanup: ' --base origin/main
```

Because the latter two commands change commit IDs, documentation should
recommend an explicit `--base` and make the generated backup branch visible in
the command's safety guidance.

Existing callers of the former repository URL must be migrated to the new
`github:willyrgf/ttools` dispatcher or direct package path. The old default-app
behavior is intentionally not preserved, and the repository must not add a
compatibility wrapper or legacy mode.

## Open decisions

- The closure-size threshold at which individual `#tool` execution becomes the
  preferred documented path.
