# RFC: Reposition the repository as `tools`

- Status: Proposed
- Date: 2026-07-14

## Summary

Reposition the current `nix-cleanup` repository as a small collection of useful
tools published from `github:willyrgf/tools`.

The repository has one public entrypoint. The default Nix app is a dispatcher
named `tools`, initially exposing `nix-cleanup` and `git-history`:

```bash
nix run 'github:willyrgf/tools'
nix run 'github:willyrgf/tools' -- list
nix run 'github:willyrgf/tools' -- nix-cleanup --quick
nix run 'github:willyrgf/tools' -- <tool-name> [args...]
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

The generated executable is `tools`.

```text
tools                         Show the catalog and usage.
tools list                    List available tools.
tools --help                 Show dispatcher help.
tools <tool-name> [args...]  Execute one tool and pass arguments through.
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

## Repository layout

```text
flake.nix
flake.lock
README.md
bin/
  tools                         Generated-dispatcher source or template.
tools/
  nix-cleanup/
    nix-cleanup.sh              Tool source.
    package.nix                  Tool derivation.
    tests/
      cli.bats                   Tool-specific tests.
  git-history/
    git-history.sh               Tool source.
    package.nix                  Tool derivation.
    tests/
      cli.bats                   Help and argument-validation tests.
      rewrite.bats               Fixture-based history rewrite tests.
  another-tool/
    main.py
    package.nix
    tests/
```

Each immediate child directory of `tools/` is one tool. A directory is valid
only when it contains `package.nix`. Shared repository code, if it becomes
necessary, belongs outside `tools/<name>` and should be introduced only after
repetition is demonstrated.

## Tool package contract

Each `tools/<name>/package.nix` receives the package set, library, and
filesystem-derived tool name, then returns one executable derivation:

```nix
{ pkgs, lib, toolName }:

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
- The derivation must produce an executable program.
- The package owns all runtime dependencies; it must not rely on ambient host
  language runtimes or tools.
- One directory represents one public command. Tools that expose several
  unrelated commands should be split into separate directories.

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
`./tools`, retain directories, validate that each contains `package.nix`, and
sort the names for deterministic output.

Conceptually:

```nix
toolNames = sortedImmediateDirectories ./tools;

toolPackages = lib.genAttrs toolNames (toolName:
  import (./tools + "/${toolName}/package.nix") {
    inherit pkgs lib toolName;
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

The default `tools` executable is generated from `toolInfo`. It contains:

- a sorted catalog of names and descriptions;
- a dispatch case for each tool name;
- the absolute Nix store path of each tool's main executable.

This is discovery at flake evaluation/build time, not runtime introspection of
Nix derivations. The executable receives a complete generated catalog and does
not need to invoke Nix to discover tools.

The outputs should look conceptually like this:

```nix
packages = toolPackages // {
  default = toolsEntrypoint;
};

apps.default = {
  type = "app";
  program = "${toolsEntrypoint}/bin/tools";
};
```

There is no handwritten list of tools in the dispatcher and no separate
registry to keep synchronized with the filesystem.

## Closure-size tradeoff

Because the generated dispatcher references every tool executable, the default
entrypoint's Nix closure includes every packaged tool. This is the simplest
implementation and is appropriate while the collection remains genuinely
small.

The flake should also expose individual packages:

```bash
nix run 'github:willyrgf/tools#nix-cleanup' -- --quick
nix run 'github:willyrgf/tools#git-history' -- review --base origin/main
```

That provides a smaller escape hatch for a tool with a large language runtime.
If the default closure later becomes a real problem, measure it first and
revisit the packaging model. A runtime dispatcher that recursively invokes
`nix run` is deliberately out of scope because it introduces extra latency,
revision ambiguity, and dependence on a second Nix evaluation.

## Testing and quality checks

The existing `nix-cleanup` tests move with the tool. The root flake should
provide a deterministic check for each discovered tool, with tool-specific
checks kept near that tool where practical.

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
4. Add the default `tools` app and package outputs for discovered tools.
5. Update the README, CI workflow, development shells, and examples.
6. Validate the local commands before renaming the GitHub repository to
   `tools`.
7. Add future utilities as new `tools/<name>/` directories.

The new canonical cleanup command is:

```bash
nix run 'github:willyrgf/tools' -- nix-cleanup --older-than 30d
```

The initial Git history commands are:

```bash
nix run 'github:willyrgf/tools' -- git-history review --base origin/main
nix run 'github:willyrgf/tools' -- git-history fix-messages --base origin/main --max-subject-length 72
nix run 'github:willyrgf/tools' -- git-history add-prefix 'cleanup: ' --base origin/main
```

Because the latter two commands change commit IDs, documentation should
recommend an explicit `--base` and make the generated backup branch visible in
the command's safety guidance.

If existing cron jobs or scripts depend on
`github:willyrgf/nix-cleanup` being a direct cleanup app, keep a temporary
compatibility wrapper or repository until those callers are migrated. A GitHub
repository rename may redirect the old URL, but it cannot preserve the old
default-app behavior after this repository becomes a dispatcher.

## Open decisions

- Whether to provide a temporary legacy mode for old `nix-cleanup` flags.
- Whether per-tool checks should be discovered through an optional conventional
  file such as `check.nix`, or remain explicit in the flake while the test
  layout settles.
- The closure-size threshold at which individual `#tool` execution becomes the
  preferred documented path.
