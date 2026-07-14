#!/usr/bin/env bats

setup_file() {
  export NIX_CLEANUP_BIN="${NIX_CLEANUP_BIN:-$(pwd)/nix-cleanup.sh}"
}

setup() {
  export TEST_TMPDIR
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_write_mock_sudo() {
  local dir=$1

  cat > "$dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-v" ]; then
  exit 0
fi

if [ "${1:-}" = "-H" ]; then
  shift
fi

exec "$@"
EOF
  chmod +x "$dir/sudo"
}

_write_mock_crontab() {
  local dir=$1

  cat > "$dir/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${CRONTAB_MOCK_FILE:?CRONTAB_MOCK_FILE must be set}"

if [ "${1:-}" = "-l" ]; then
  if [ -f "$state_file" ]; then
    cat "$state_file"
    exit 0
  fi

  exit 1
fi

if [ "$#" -eq 1 ]; then
  cat "$1" > "$state_file"
  exit 0
fi

echo "unsupported crontab arguments: $*" >&2
exit 1
EOF
  chmod +x "$dir/crontab"
}

_write_mock_find_empty() {
  local dir=$1

  cat > "$dir/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$dir/find"
}

@test "--help succeeds" {
  run "$NIX_CLEANUP_BIN" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"clean dead nix store paths safely"* ]]
}

@test "--older-than rejects invalid duration" {
  run "$NIX_CLEANUP_BIN" --older-than bad

  [ "$status" -ne 0 ]
  [[ "$output" == *"--older-than expects the format <number>d"* ]]
}

@test "conflicting selectors fail fast" {
  run "$NIX_CLEANUP_BIN" --system --older-than 30d

  [ "$status" -ne 0 ]
  [[ "$output" == *"pick exactly one target selector"* ]]
}

@test "--jobs requires a positive integer" {
  run "$NIX_CLEANUP_BIN" --system --jobs 0

  [ "$status" -ne 0 ]
  [[ "$output" == *"--jobs expects a positive integer"* ]]
}

@test "--quick defaults to --system and --no-gc" {
  local mock_dir="$TEST_TMPDIR/mock-quick"
  mkdir -p "$mock_dir"
  _write_mock_find_empty "$mock_dir"

  run env PATH="$mock_dir:$PATH" "$NIX_CLEANUP_BIN" --quick

  [ "$status" -eq 0 ]
  [[ "$output" == *"Quick mode default: using --system target."* ]]
  [[ "$output" == *"Quick mode default: skipping final GC (--no-gc)."* ]]
}

@test "--add-cron normalizes plain commands to @daily" {
  local mock_dir="$TEST_TMPDIR/mock-cron"
  local state_file="$TEST_TMPDIR/root-crontab"
  mkdir -p "$mock_dir"
  _write_mock_sudo "$mock_dir"
  _write_mock_crontab "$mock_dir"

  run env \
    PATH="$mock_dir:$PATH" \
    CRONTAB_MOCK_FILE="$state_file" \
    "$NIX_CLEANUP_BIN" \
    --add-cron "nix-cleanup --quick --gc --yes --jobs 4"

  [ "$status" -eq 0 ]
  run grep -Fx "@daily nix-cleanup --quick --gc --yes --jobs 4" "$state_file"
  [ "$status" -eq 0 ]
}

@test "--add-cron keeps full cron entries unchanged" {
  local mock_dir="$TEST_TMPDIR/mock-cron"
  local state_file="$TEST_TMPDIR/root-crontab"
  local cron_entry="0 3 * * * nix-cleanup --quick --gc --yes --jobs 4"
  mkdir -p "$mock_dir"
  _write_mock_sudo "$mock_dir"
  _write_mock_crontab "$mock_dir"

  run env \
    PATH="$mock_dir:$PATH" \
    CRONTAB_MOCK_FILE="$state_file" \
    "$NIX_CLEANUP_BIN" \
    --add-cron "$cron_entry"

  [ "$status" -eq 0 ]
  run grep -Fx "$cron_entry" "$state_file"
  [ "$status" -eq 0 ]
}

@test "--add-cron does not duplicate existing entries" {
  local mock_dir="$TEST_TMPDIR/mock-cron"
  local state_file="$TEST_TMPDIR/root-crontab"
  local cron_entry="@daily nix-cleanup --quick --gc --yes --jobs 4"
  mkdir -p "$mock_dir"
  _write_mock_sudo "$mock_dir"
  _write_mock_crontab "$mock_dir"
  printf '%s\n' "$cron_entry" > "$state_file"

  run env \
    PATH="$mock_dir:$PATH" \
    CRONTAB_MOCK_FILE="$state_file" \
    "$NIX_CLEANUP_BIN" \
    --add-cron "nix-cleanup --quick --gc --yes --jobs 4"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cron entry already exists in root crontab."* ]]

  run wc -l < "$state_file"
  [ "$status" -eq 0 ]
  [ "${output//[[:space:]]/}" -eq 1 ]
}
