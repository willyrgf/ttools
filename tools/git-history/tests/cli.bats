#!/usr/bin/env bats

setup_file() {
  export GIT_HISTORY_BIN="${GIT_HISTORY_BIN:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/git-history.sh}"
}

setup() {
  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d)"
  export REPO="$TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.name "Fixture User"
  git -C "$REPO" config user.email "fixture@example.com"
  git -C "$REPO" config commit.gpgSign false
  cd "$REPO"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_commit() {
  local message=$1
  local file="$TEST_TMPDIR/message"

  printf '%s' "$message" > "$file"
  git commit --allow-empty --allow-empty-message -q -F "$file"
}

@test "--help and -h are side-effect-free and use the packaged name" {
  run "$GIT_HISTORY_BIN" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"git-history review"* ]]
  [[ "$output" != *"./git-history.sh"* ]]

  run "$GIT_HISTORY_BIN" -h

  [ "$status" -eq 0 ]
  [[ "$output" == *"git-history fix-messages"* ]]
}

@test "an explicit command is required" {
  run "$GIT_HISTORY_BIN"

  [ "$status" -ne 0 ]
  [[ "$output" == *"a command is required"* ]]
}

@test "old command aliases are rejected" {
  for alias in --review --fix; do
    run "$GIT_HISTORY_BIN" "$alias"

    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command"* || "$output" == *"command is required"* ]]
  done
}

@test "option values use the canonical separated form" {
  run "$GIT_HISTORY_BIN" review --base=HEAD

  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]

  run "$GIT_HISTORY_BIN" review --max-subject-length=72

  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "the end-of-options marker is accepted" {
  _commit "base"
  local base
  base="$(git rev-parse HEAD)"
  _commit "branch commit"

  run "$GIT_HISTORY_BIN" review --base "$base" --

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "invalid arguments do not mutate the repository" {
  _commit "base"
  local before_head before_refs
  before_head="$(git rev-parse HEAD)"
  before_refs="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads)"

  run "$GIT_HISTORY_BIN" review --base does-not-exist

  [ "$status" -ne 0 ]
  [[ "$output" == *"base revision is not a commit"* ]]
  [ "$(git rev-parse HEAD)" = "$before_head" ]
  [ "$(git for-each-ref --format='%(refname) %(objectname)' refs/heads)" = "$before_refs" ]
}

@test "review results use stdout and diagnostics use stderr" {
  _commit "base"
  local base stdout stderr
  base="$(git rev-parse HEAD)"
  _commit "branch commit"
  stdout="$TEST_TMPDIR/stdout"
  stderr="$TEST_TMPDIR/stderr"

  "$GIT_HISTORY_BIN" review --base "$base" > "$stdout" 2> "$stderr"

  grep -F "OK" "$stdout" > /dev/null
  grep -F "Reviewing" "$stderr" > /dev/null
  grep -F "Base:" "$stderr" > /dev/null
}
