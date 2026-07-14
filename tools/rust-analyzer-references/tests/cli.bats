#!/usr/bin/env bats

setup() {
  workspace="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$workspace"
  cp "$RUST_ANALYZER_REFERENCES_FIXTURE" "$workspace/sample.rs"
  cp "$RUST_ANALYZER_REFERENCES_MANIFEST" "$workspace/Cargo.toml"
  export RUST_ANALYZER_REFERENCES_FAKE_RA="$RUST_ANALYZER_REFERENCES_FAKE_SOURCE"
  unset RUST_ANALYZER_REFERENCES_RETRY_METHOD
}

run_tool() {
  "$RUST_ANALYZER_REFERENCES_BIN" \
    --workspace "$workspace" \
    --rust-analyzer "$RUST_ANALYZER_REFERENCES_FAKE_RA" \
    "$@"
}

@test "help does not start rust-analyzer" {
  run "$RUST_ANALYZER_REFERENCES_BIN" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"--kinds KINDS"* ]]
  [[ "$output" == *"--count COUNT"* ]]
}

@test "invalid kinds fail before analyzer startup" {
  run run_tool --kinds nope --count 0

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown kind(s): nope"* ]]
}

@test "all expands to every supported kind" {
  run run_tool --kinds all --count 99 --output json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
assert data["kinds"] == [
    "enum",
    "function",
    "method",
    "struct",
    "trait",
    "type-alias",
    "union",
]
'
}

@test "negative counts fail validation" {
  run run_tool --kinds function --count -1

  [ "$status" -eq 2 ]
  [[ "$output" == *"--count must be non-negative"* ]]
}

@test "missing scan paths fail validation" {
  run run_tool --kinds function --count 0 missing.rs

  [ "$status" -eq 2 ]
  [[ "$output" == *"scan path does not exist: missing.rs"* ]]
}

@test "missing project configuration fails before analyzer startup" {
  rm "$workspace/Cargo.toml"
  run run_tool --kinds function --count 0

  [ "$status" -eq 2 ]
  [[ "$output" == *"workspace does not contain Cargo.toml or rust-project.json"* ]]
}

@test "zero-reference exported functions and methods are reported" {
  run run_tool \
    --kinds function,method \
    --visibility exported \
    --count 0 \
    --output json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
names = {item["name"] for item in data["matches"]}
assert names == {"unused_public", "method"}, names
assert all(item["reference_count"] == 0 for item in data["matches"])
'
}

@test "exactly one reference selects only the single-use type" {
  run run_tool \
    --kinds enum,struct,trait,type-alias,union \
    --visibility any \
    --count 1 \
    --output json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
names = {item["name"] for item in data["matches"]}
assert names == {"OneUse"}, names
assert data["matches"][0]["references"][0]["column"] > 1
'
}

@test "busy reference requests are retried" {
  export RUST_ANALYZER_REFERENCES_RETRY_METHOD=references
  run run_tool --kinds function --visibility exported --count 1 --output json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
names = {item["name"] for item in data["matches"]}
assert names == {"used_public"}, names
'
}

@test "UTF-16 reference columns are converted to display columns" {
  run run_tool --kinds function --visibility exported --count 1 --output json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
reference = data["matches"][0]["references"][0]
assert reference["path"] == "sample.rs"
assert reference["line"] == 18
assert reference["column"] == 16
'
}

@test "fail-on-findings returns one" {
  run run_tool --kinds function --visibility exported --count 0 --fail-on-findings

  [ "$status" -eq 1 ]
  [[ "$output" == *"unused_public"* ]]
}

@test "no findings succeeds" {
  run run_tool --kinds function --visibility exported --count 99 --fail-on-findings

  [ "$status" -eq 0 ]
}

@test "paths after the option terminator are accepted" {
  run run_tool \
    --kinds function \
    --visibility exported \
    --count 0 \
    -- \
    "$workspace/sample.rs"

  [ "$status" -eq 0 ]
  [[ "$output" == *"unused_public"* ]]
}
