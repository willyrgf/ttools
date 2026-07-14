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
  local author_name=$2
  local author_email=$3
  local author_date=$4
  local committer_name=$5
  local committer_email=$6
  local committer_date=$7
  local message_file="$TEST_TMPDIR/message-$RANDOM"

  printf '%s' "$message" > "$message_file"
  GIT_AUTHOR_NAME="$author_name" \
    GIT_AUTHOR_EMAIL="$author_email" \
    GIT_AUTHOR_DATE="$author_date" \
    GIT_COMMITTER_NAME="$committer_name" \
    GIT_COMMITTER_EMAIL="$committer_email" \
    GIT_COMMITTER_DATE="$committer_date" \
    git commit --allow-empty --allow-empty-message -q -F "$message_file"
}

_subjects() {
  git log --reverse --format='%s' "$BASE..HEAD"
}

_trees_and_metadata() {
  local commit

  while IFS= read -r commit; do
    git show -s --format='%T|%an|%ae|%aI|%cn|%ce|%cI' "$commit"
  done < <(git rev-list --reverse --topo-order "$BASE..HEAD")
}

_parent_counts() {
  git rev-list --reverse --topo-order --parents "$BASE..HEAD" | awk '{ print NF - 1 }'
}

@test "review uses an explicit base and detects all message violations" {
  _commit "base" "Base Author" "base@example.com" "2024-01-01T00:00:00+0000" \
    "Base Committer" "base-committer@example.com" "2024-01-01T00:00:01+0000"
  BASE="$(git rev-parse HEAD)"
  _commit "" "Empty Author" "empty@example.com" "2024-01-02T00:00:00+0000" \
    "Empty Committer" "empty-committer@example.com" "2024-01-02T00:00:01+0000"
  _commit $'multi-line subject\n\nbody' "Multi Author" "multi@example.com" "2024-01-03T00:00:00+0000" \
    "Multi Committer" "multi-committer@example.com" "2024-01-03T00:00:01+0000"
  _commit $'trailer subject\n\nSigned-off-by: Someone <someone@example.com>' "Trailer Author" "trailer@example.com" "2024-01-04T00:00:00+0000" \
    "Trailer Committer" "trailer-committer@example.com" "2024-01-04T00:00:01+0000"
  _commit "subject longer than ten" "Long Author" "long@example.com" "2024-01-05T00:00:00+0000" \
    "Long Committer" "long-committer@example.com" "2024-01-05T00:00:01+0000"

  run "$GIT_HISTORY_BIN" review --base "$BASE" --max-subject-length 10

  [ "$status" -ne 0 ]
  [[ "$output" == *"empty commit message"* ]]
  [[ "$output" == *"message has 3 lines"* ]]
  [[ "$output" == *"contains disallowed author/trailer line"* ]]
  [[ "$output" == *"subject is 22 characters; limit is 10"* ]]
}

@test "fix-messages preserves trees, topology, and metadata and creates a backup" {
  _commit "base" "Base Author" "base@example.com" "2024-02-01T00:00:00+0000" \
    "Base Committer" "base-committer@example.com" "2024-02-01T00:00:01+0000"
  BASE="$(git rev-parse HEAD)"
  _commit $'  normalize   this  \n\nbody' "First Author" "first@example.com" "2024-02-02T00:00:00+0000" \
    "First Committer" "first-committer@example.com" "2024-02-02T00:00:01+0000"
  _commit "keep this" "Second Author" "second@example.com" "2024-02-03T00:00:00+0000" \
    "Second Committer" "second-committer@example.com" "2024-02-03T00:00:01+0000"

  local original_head original_tree original_metadata original_parents before_refs backup_branch
  original_head="$(git rev-parse HEAD)"
  original_tree="$(git rev-parse HEAD^{tree})"
  original_metadata="$(_trees_and_metadata)"
  original_parents="$(_parent_counts)"
  before_refs="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads)"

  run "$GIT_HISTORY_BIN" fix-messages --base "$BASE"

  [ "$status" -eq 0 ]
  backup_branch="$(printf '%s\n' "$output" | sed -n 's/^Backup branch: //p')"
  [ -n "$backup_branch" ]
  [ "$(git rev-parse "$backup_branch")" = "$original_head" ]
  [ "$(git rev-parse HEAD)" != "$original_head" ]
  [ "$(git rev-parse HEAD^{tree})" = "$original_tree" ]
  [ "$(_trees_and_metadata)" = "$original_metadata" ]
  [ "$(_parent_counts)" = "$original_parents" ]
  [ "$(_subjects)" = $'normalize this\nkeep this' ]
  [ "$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | grep -F "$backup_branch")" != "" ]
  [ "$(git for-each-ref --format='%(refname) %(objectname)' refs/heads | grep -F "refs/heads/main ")" != "$(printf '%s\n' "$before_refs" | grep -F 'refs/heads/main ')" ]
}

@test "fix-messages can truncate a long subject at a word boundary" {
  _commit "base" "Base Author" "base@example.com" "2024-03-01T00:00:00+0000" \
    "Base Committer" "base-committer@example.com" "2024-03-01T00:00:01+0000"
  BASE="$(git rev-parse HEAD)"
  _commit "a very long subject for truncation" "Author" "author@example.com" "2024-03-02T00:00:00+0000" \
    "Committer" "committer@example.com" "2024-03-02T00:00:01+0000"

  run "$GIT_HISTORY_BIN" fix-messages --base "$BASE" --max-subject-length 15 --truncate-long

  [ "$status" -eq 0 ]
  [ "$(git log -1 --format='%s')" = "a very long" ]
  [ "${#output}" -gt 0 ]
}

@test "validation failure leaves history untouched" {
  _commit "base" "Base Author" "base@example.com" "2024-04-01T00:00:00+0000" \
    "Base Committer" "base-committer@example.com" "2024-04-01T00:00:01+0000"
  BASE="$(git rev-parse HEAD)"
  _commit "" "Empty Author" "empty@example.com" "2024-04-02T00:00:00+0000" \
    "Empty Committer" "empty-committer@example.com" "2024-04-02T00:00:01+0000"

  local before_head before_refs
  before_head="$(git rev-parse HEAD)"
  before_refs="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads)"

  run "$GIT_HISTORY_BIN" fix-messages --base "$BASE"

  [ "$status" -ne 0 ]
  [ "$(git rev-parse HEAD)" = "$before_head" ]
  [ "$(git for-each-ref --format='%(refname) %(objectname)' refs/heads)" = "$before_refs" ]
}

@test "add-prefix is idempotent and creates a backup only when needed" {
  _commit "base" "Base Author" "base@example.com" "2024-05-01T00:00:00+0000" \
    "Base Committer" "base-committer@example.com" "2024-05-01T00:00:01+0000"
  BASE="$(git rev-parse HEAD)"
  _commit "first subject" "First Author" "first@example.com" "2024-05-02T00:00:00+0000" \
    "First Committer" "first-committer@example.com" "2024-05-02T00:00:01+0000"
  _commit "cleanup: second subject" "Second Author" "second@example.com" "2024-05-03T00:00:00+0000" \
    "Second Committer" "second-committer@example.com" "2024-05-03T00:00:01+0000"

  run "$GIT_HISTORY_BIN" add-prefix 'cleanup: ' --base "$BASE"

  [ "$status" -eq 0 ]
  [ "$(git log --reverse --format='%s' "$BASE..HEAD")" = $'cleanup: first subject\ncleanup: second subject' ]
  local before_second_run
  before_second_run="$(git rev-parse HEAD) $(git for-each-ref --format='%(refname) %(objectname)' refs/heads/backup)"

  run "$GIT_HISTORY_BIN" add-prefix 'cleanup: ' --base "$BASE"

  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD) $(git for-each-ref --format='%(refname) %(objectname)' refs/heads/backup)" = "$before_second_run" ]
}

@test "rewriting a merge preserves parent topology" {
  _commit "base" "Base Author" "base@example.com" "2024-06-01T00:00:00+0000" \
    "Base Committer" "base-committer@example.com" "2024-06-01T00:00:01+0000"
  BASE="$(git rev-parse HEAD)"
  _commit "main subject" "Main Author" "main@example.com" "2024-06-02T00:00:00+0000" \
    "Main Committer" "main-committer@example.com" "2024-06-02T00:00:01+0000"
  git checkout -q -b side "$BASE"
  _commit "side subject" "Side Author" "side@example.com" "2024-06-03T00:00:00+0000" \
    "Side Committer" "side-committer@example.com" "2024-06-03T00:00:01+0000"
  git checkout -q main
  git merge --no-ff -q -m "merge subject" side

  local original_tree original_metadata original_parents
  original_tree="$(git rev-parse HEAD^{tree})"
  original_metadata="$(_trees_and_metadata)"
  original_parents="$(_parent_counts)"

  run "$GIT_HISTORY_BIN" add-prefix 'cleanup: ' --base "$BASE"

  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD^{tree})" = "$original_tree" ]
  [ "$(_trees_and_metadata)" = "$original_metadata" ]
  [ "$(_parent_counts)" = "$original_parents" ]
  [ "$(git log --reverse --format='%s' "$BASE..HEAD" | grep -vc '^cleanup: ')" -eq 0 ]
}
