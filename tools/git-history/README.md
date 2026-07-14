# git-history

Review commits on the current branch and, only when explicitly requested,
normalize selected commit messages or add a subject prefix.

## Usage

```text
git-history review [--base <rev>] [--max-subject-length <n>]
git-history fix-messages [--base <rev>] [--max-subject-length <n>] [--truncate-long]
git-history add-prefix <prefix> [--base <rev>]
git-history -h | --help
```

The selected range is `merge-base(<base>, HEAD)..HEAD`. Base selection defaults
to `origin/HEAD`, `origin/main`, `origin/master`, `main`, `master`, `trunk`,
then `@{upstream}`. Pass `--base` for reproducible work.

Run through the dispatcher:

```bash
nix run 'github:willyrgf/ttools' -- git-history review --base origin/main
```

## Commands

- `review` is read-only. It reports empty, multi-line, trailer/author, and
  overlong message violations.
- `fix-messages` normalizes selected subjects. Use `--truncate-long` with
  `--max-subject-length <N>` to truncate long subjects at a word boundary.
- `add-prefix <prefix>` adds a literal, case-sensitive subject prefix and is
  idempotent. Message bodies are preserved.

## Options

- `--base <rev>` selects the comparison base.
- `--max-subject-length <N>` sets the maximum subject length for `review` and
  `fix-messages`.
- `--truncate-long` lets `fix-messages` truncate long subjects at a word
  boundary; it requires `--max-subject-length`.
- `--` ends option parsing. Long options use the canonical `--option <value>`
  form.

The review and fix-messages rules require a single non-empty message line with
no author or trailer lines such as `Author:`, `Co-authored-by:`,
`Signed-off-by:`, `Reviewed-by:`, or `Change-Id:`.

## Safety

`review` never mutates the repository. The rewriting commands require a
checked-out branch with no staged or unstaged tracked changes. After validating
all selected commits, they create a backup branch named like
`backup/git-history-<branch>-<timestamp>` before moving the current branch.

Rewrites preserve each final tree, parent topology, author and committer
identities, and author and committer dates. Signed commits and commits with
unsupported extra headers are refused. Commit IDs change when messages or
rewritten parents change.

Use `--` to end option parsing. Normal results go to stdout; diagnostics and
progress go to stderr. Rewriting is never implicit.

Examples:

```bash
nix run . -- git-history review --base origin/main
nix run . -- git-history fix-messages --base origin/main --max-subject-length 72
nix run . -- git-history add-prefix 'cleanup: ' --base origin/main
```
