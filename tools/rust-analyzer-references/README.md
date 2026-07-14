# rust-analyzer-references

Report Rust definitions with an exact number of workspace references returned
by rust-analyzer.

## Usage

```text
rust-analyzer-references --kinds <kinds> --count <n> [options] [paths...]
```

Find exported functions and methods with no workspace references:

```bash
rust-analyzer-references \
  --kinds function,method \
  --visibility exported \
  --count 0 \
  --fail-on-findings
```

Find type-like definitions referenced exactly once:

```bash
rust-analyzer-references \
  --kinds enum,struct,trait,type-alias,union \
  --visibility any \
  --count 1
```

The tool scans Rust files below `--workspace`, or the supplied files and
directories, and asks rust-analyzer for references at each definition's LSP
selection position. `--count` excludes the definition itself and counts only
locations inside the workspace. Build, cache, VCS, and hidden directories are
skipped.

The workspace must be loadable by rust-analyzer through its normal project
configuration, such as Cargo metadata or `rust-project.json`. The tool does
not invoke Cargo or modify the project.

Supported kinds are `enum`, `function`, `method`, `struct`, `trait`,
`type-alias`, and `union`; use `--kinds all` to select all of them.
`--visibility exported` selects plain `pub` items; `--visibility any` includes
private and restricted items.

Normal findings go to stdout. Diagnostics and verbose progress go to stderr.
`--output json` emits a stable machine-readable report. The tool never edits
source files. A zero workspace-reference result is cleanup evidence, not proof
that an exported API is safe to remove: downstream users outside the analyzed
workspace are not visible.
