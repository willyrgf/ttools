#!/usr/bin/env bats

setup() {
  workspace="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$workspace"/subdir/nested "$workspace"/repo

  printf '%s\n' '# Python file' > "$workspace/file.py"
  printf '%s\n' 'console.log("test");' > "$workspace/file.js"
  printf '%s\n' '# Markdown file' > "$workspace/README.md"
  printf '%s\n' 'nested Python' > "$workspace/subdir/nested/deep.py"
  printf '\000\001\002\003' > "$workspace/binary.bin"
  : > "$workspace/empty.txt"

  printf '%s\n' 'tracked' > "$workspace/repo/tracked.txt"
  printf '%s\n' 'untracked' > "$workspace/repo/untracked.txt"
  printf '%s\n' 'ignored' > "$workspace/repo/ignored.txt"
  printf '%s\n' 'ignored.txt' > "$workspace/repo/.gitignore"
  git -C "$workspace/repo" init -q
  git -C "$workspace/repo" add tracked.txt .gitignore

  export DUMP2LLM_CWD="$workspace"
}

run_tool() {
  (cd "$DUMP2LLM_CWD" && "$DUMP2LLM_BIN" "$@")
}

@test "help is successful and side-effect free" {
  run run_tool --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: dump2llm"* ]]
  [[ "$output" == *"--ignore"* ]]
  [[ "$output" != *"<<< FILE:"* ]]
}

@test "missing inputs and unknown options fail validation" {
  run run_tool
  [ "$status" -eq 2 ]
  [[ "$output" == *"at least one input is required"* ]]

  run run_tool --unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: --unknown"* ]]
}

@test "single files are dumped and binary or empty files are skipped" {
  run run_tool file.py binary.bin empty.txt

  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE: file.py >>>"* ]]
  [[ "$output" == *"# Python file"* ]]
  [[ "$output" != *"binary.bin"* ]]
  [[ "$output" != *"empty.txt"* ]]
}

@test "directories and recursive globs collect text files" {
  run run_tool subdir
  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE: subdir/nested/deep.py >>>"* ]]

  run run_tool '**/*.py'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE: file.py >>>"* ]]
  [[ "$output" == *"<<< FILE: subdir/nested/deep.py >>>"* ]]
}

@test "ignore patterns and overlapping inputs are honored" {
  run run_tool --ignore '*.js,subdir' '**/*'

  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE: file.py >>>"* ]]
  [[ "$output" != *"file.js"* ]]
  [[ "$output" != *"subdir/nested/deep.py"* ]]

  run run_tool file.py file.py '*.py'
  [ "$status" -eq 0 ]
  [ "$(grep -c '<<< FILE: file.py >>>' <<< "$output")" -eq 1 ]
}

@test "option terminator permits paths beginning with a dash" {
  printf '%s\n' 'dash file' > "$DUMP2LLM_CWD/-dash.txt"

  run run_tool -- -dash.txt

  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE: -dash.txt >>>"* ]]
}

@test "missing explicit files fail while empty globs are no-ops" {
  run run_tool missing.txt
  [ "$status" -eq 2 ]
  [[ "$output" == *"input is not a regular file: missing.txt"* ]]

  run run_tool '*.missing'
  [ "$status" -eq 0 ]
  [[ "$output" != *"<<< FILE:"* ]]
}

@test "Git directories include tracked and untracked non-ignored files" {
  run run_tool repo

  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE: repo/tracked.txt >>>"* ]]
  [[ "$output" == *"<<< FILE: repo/untracked.txt >>>"* ]]
  [[ "$output" != *"repo/ignored.txt"* ]]
  [[ "$output" != *"repo/.git/"* ]]
}

@test "a local Git URL can be cloned and dumped" {
  source_repo="$BATS_TEST_TMPDIR/source-repo"
  mkdir -p "$source_repo"
  printf '%s\n' 'from clone' > "$source_repo/cloned.txt"
  git -C "$source_repo" init -q
  git -C "$source_repo" add cloned.txt
  git -C "$source_repo" -c user.name=test -c user.email=test@example.invalid commit -q -m initial

  run run_tool "file://$source_repo"

  [ "$status" -eq 0 ]
  [[ "$output" == *"<<< FILE:"* ]]
  [[ "$output" == *"from clone"* ]]
  [[ "$output" != *".git/"* ]]
}
