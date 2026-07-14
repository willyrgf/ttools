# ttools

`ttools` means **tiny tools**: a focused collection of small command-line
utilities published from `github:willyrgf/ttools`.

## Run

```bash
nix run 'github:willyrgf/ttools'
nix run 'github:willyrgf/ttools' -- list
nix run 'github:willyrgf/ttools' -- <tool> [args...]
```

The dispatcher consumes the tool name and passes all remaining arguments,
input, output, signals, and exit status through unchanged. Direct packages are
also available as `.#nix-cleanup` and `.#git-history`.

## Tiny tools

- [nix-cleanup](tools/nix-cleanup/README.md) — safely remove dead Nix store
  paths and optionally run garbage collection.
- [git-history](tools/git-history/README.md) — review or deliberately rewrite
  selected Git commit messages.
- [rust-analyzer-references](tools/rust-analyzer-references/README.md) — report
  Rust definitions by rust-analyzer reference count.

Each tool folder contains its implementation, package, tests, and usage
documentation. See [AGENTS.md](AGENTS.md) for contribution guidance.

## Development

```bash
nix run . -- --help
nix run . -- list
nix run .#check
nix run .#format
```

`.#format` updates Bash, Python, and Nix source files in place. Checks use
temporary fixtures. Do not run cleanup against a real store or rewrite this
repository's history while developing.
