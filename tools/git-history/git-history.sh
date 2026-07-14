#!/usr/bin/env bash
set -euo pipefail

COMMAND=""
BASE_REF=""
MAX_SUBJECT_LENGTH=""
TRUNCATE_LONG=0
MESSAGE_PREFIX=""
PREFIX_SET=0
MESSAGES_CHANGED=0
TMP_DIR=""

usage() {
  cat << 'USAGE'
Usage:
  git-history review [--base <rev>] [--max-subject-length <n>]
  git-history fix-messages [--base <rev>] [--max-subject-length <n>] [--truncate-long]
  git-history add-prefix <prefix> [--base <rev>]

Operates on commits made on the current branch, defined as:
  merge-base(<base>, HEAD)..HEAD

Base selection defaults to origin/HEAD, origin/main, origin/master, main, master,
trunk, then @{upstream}. Pass --base to make the range explicit.

The review and fix-messages commands use these message rules:
  - the commit message must be exactly one non-empty line
  - the commit message must not contain author/trailer lines such as Author:,
    Co-authored-by:, Signed-off-by:, Reviewed-by:, or Change-Id:
  - when --max-subject-length is passed, the subject must fit that limit

The add-prefix command adds the literal, case-sensitive prefix to the subject of
every selected commit that does not already start with it. Message bodies are
left unchanged, so the operation is idempotent.

The review command is read-only. The fix-messages and add-prefix commands create
a backup branch before moving the current branch and rewrite selected history.

History-changing commands keep the exact final tree and commit topology, and
preserve author and committer identities and timestamps. They create a backup
branch before moving the current branch. Commit IDs at and after the first
changed message necessarily change because the message and parent IDs are part
of a Git commit's identity.

Options:
  --base <rev>                Compare this branch against the given base.
  --max-subject-length <n>    Optional maximum allowed subject length.
  --truncate-long             In fix-messages, truncate long subjects at a word
                              boundary to fit --max-subject-length.
  -h, --help                  Show this help.

Notes:
  Git commit objects always have required author metadata. The "no authors" rule
  here means no author/co-author/trailer text inside commit messages.

  Prefixes are literal. Quote a prefix containing spaces, for example:
    git-history add-prefix 'cleanup: ' --base origin/dev

  Rewriting signed commits or commits with unusual extra headers is refused
  because those headers cannot be preserved faithfully by this script.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

trim_line() {
  local line="$1"
  line="${line//$'\r'/}"
  printf '%s' "$line" | sed \
    -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//' \
    -e 's/[[:space:]][[:space:]]*/ /g'
}

is_disallowed_line() {
  local line lower
  line="$(trim_line "$1")"
  lower="${line,,}"

  case "$lower" in
    author:* | authors:* | co-authored-by:* | signed-off-by:* | reviewed-by:* | \
      acked-by:* | tested-by:* | reported-by:* | suggested-by:* | committed-by:* | \
      committer:* | pair-programmed-by:* | change-id:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

write_normalized_message() {
  local in_file="$1"
  local out_file="$2"

  awk '
    {
      sub(/\r$/, "")
      lines[NR] = $0
    }
    END {
      n = NR
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) {
        n--
      }
      for (i = 1; i <= n; i++) {
        print lines[i]
      }
    }
  ' "$in_file" > "$out_file"
}

extract_commit_message() {
  local commit="$1"
  local out_file="$2"

  git cat-file commit "$commit" | sed '1,/^$/d' > "$out_file"
}

message_violations() {
  local normalized_file="$1"
  local subject="$2"
  local line_count subject_len line trimmed

  line_count="$(wc -l < "$normalized_file" | tr -d '[:space:]')"
  subject_len="${#subject}"

  if [[ -z "$subject" ]]; then
    printf '%s\n' "empty commit message"
  fi

  if [[ "$line_count" != "1" ]]; then
    printf 'message has %s lines after trailing blanks are ignored\n' "$line_count"
  fi

  if [[ -n "$MAX_SUBJECT_LENGTH" ]] && ((subject_len > MAX_SUBJECT_LENGTH)); then
    printf 'subject is %s characters; limit is %s\n' "$subject_len" "$MAX_SUBJECT_LENGTH"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(trim_line "$line")"
    if [[ -n "$trimmed" ]] && is_disallowed_line "$trimmed"; then
      printf 'contains disallowed author/trailer line: %s\n' "$trimmed"
    fi
  done < "$normalized_file"
}

inspect_commit() {
  local commit="$1"
  local violations_file="$2"
  local subject_file="$3"
  local message_file="$TMP_DIR/message-$commit"
  local normalized_file="$TMP_DIR/normalized-$commit"
  local subject

  extract_commit_message "$commit" "$message_file"
  write_normalized_message "$message_file" "$normalized_file"
  subject="$(trim_line "$(sed -n '1p' "$normalized_file")")"

  printf '%s\n' "$subject" > "$subject_file"
  message_violations "$normalized_file" "$subject" > "$violations_file"
}

truncate_subject() {
  local subject="$1"
  local truncated

  truncated="${subject:0:MAX_SUBJECT_LENGTH}"
  if [[ "$truncated" == *" "* ]]; then
    truncated="${truncated% *}"
  fi
  truncated="$(trim_line "$truncated")"

  if [[ -z "$truncated" ]]; then
    truncated="${subject:0:MAX_SUBJECT_LENGTH}"
  fi

  printf '%s\n' "$truncated"
}

sanitize_message() {
  local in_file="$1"
  local out_file="$2"
  local normalized_file="$TMP_DIR/sanitize-normalized"
  local subject="" line trimmed

  write_normalized_message "$in_file" "$normalized_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(trim_line "$line")"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    if is_disallowed_line "$trimmed"; then
      return 3
    fi
    subject="$trimmed"
    break
  done < "$normalized_file"

  if [[ -z "$subject" ]]; then
    return 1
  fi

  if [[ -n "$MAX_SUBJECT_LENGTH" ]] && ((${#subject} > MAX_SUBJECT_LENGTH)); then
    if ((TRUNCATE_LONG)); then
      subject="$(truncate_subject "$subject")"
    else
      return 2
    fi
  fi

  printf '%s\n' "$subject" > "$out_file"
}

add_prefix_to_message() {
  local in_file="$1"
  local out_file="$2"
  local subject=""

  IFS= read -r subject < "$in_file" || true

  if [[ "$subject" == "$MESSAGE_PREFIX"* ]]; then
    cp "$in_file" "$out_file"
    return
  fi

  {
    printf '%s%s\n' "$MESSAGE_PREFIX" "$subject"
    sed -n '2,$p' "$in_file"
  } > "$out_file"
}

parse_args() {
  if (($# == 0)); then
    die "a command is required: review, fix-messages, or add-prefix"
  fi

  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    review | fix-messages | add-prefix)
      COMMAND="$1"
      shift
      ;;
    *)
      die "unknown command: $1"
      ;;
  esac

  while (($#)); do
    case "$1" in
      --base)
        [[ $# -ge 2 ]] || die "--base requires a revision"
        BASE_REF="$2"
        shift 2
        ;;
      --max-subject-length)
        [[ $# -ge 2 ]] || die "--max-subject-length requires a number"
        MAX_SUBJECT_LENGTH="$2"
        shift 2
        ;;
      --truncate-long)
        TRUNCATE_LONG=1
        shift
        ;;
      --)
        shift
        if [[ "$COMMAND" == "add-prefix" ]] && ((!PREFIX_SET)) && (($#)); then
          MESSAGE_PREFIX="$1"
          PREFIX_SET=1
          shift
        fi
        (($# == 0)) || die "unexpected argument: $1"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ "$COMMAND" == "add-prefix" ]] && ((!PREFIX_SET)); then
          MESSAGE_PREFIX="$1"
          PREFIX_SET=1
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done

  [[ -z "$MAX_SUBJECT_LENGTH" || "$MAX_SUBJECT_LENGTH" =~ ^[1-9][0-9]*$ ]] ||
    die "--max-subject-length must be a positive integer"

  if [[ "$COMMAND" == "add-prefix" ]]; then
    ((PREFIX_SET)) || die "add-prefix requires a prefix"
    [[ -n "$MESSAGE_PREFIX" ]] || die "prefix must not be empty"
    [[ "$MESSAGE_PREFIX" != *$'\n'* && "$MESSAGE_PREFIX" != *$'\r'* ]] ||
      die "prefix must be a single line"
    [[ -z "$MAX_SUBJECT_LENGTH" ]] ||
      die "--max-subject-length is not supported by add-prefix"
  fi

  if ((TRUNCATE_LONG)) && [[ -z "$MAX_SUBJECT_LENGTH" ]]; then
    die "--truncate-long requires --max-subject-length"
  fi

  if ((TRUNCATE_LONG)) && [[ "$COMMAND" != "fix-messages" ]]; then
    die "--truncate-long is only supported by fix-messages"
  fi
}

resolve_base_ref() {
  local ref

  if [[ -n "$BASE_REF" ]]; then
    git rev-parse --verify --quiet "$BASE_REF^{commit}" > /dev/null ||
      die "base revision is not a commit: $BASE_REF"
    printf '%s\n' "$BASE_REF"
    return
  fi

  ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)"
  if [[ -n "$ref" ]] && git rev-parse --verify --quiet "$ref^{commit}" > /dev/null; then
    printf '%s\n' "$ref"
    return
  fi

  for ref in origin/main origin/master main master trunk; do
    if git rev-parse --verify --quiet "$ref^{commit}" > /dev/null; then
      printf '%s\n' "$ref"
      return
    fi
  done

  if git rev-parse --verify --quiet '@{upstream}^{commit}' > /dev/null; then
    printf '%s\n' '@{upstream}'
    return
  fi

  die "could not determine branch base; pass --base <rev>"
}

load_branch_commits() {
  local base_ref="$1"
  local commits_var="$2"
  local merge_base_var="$3"
  local found_merge_base

  found_merge_base="$(git merge-base "$base_ref" HEAD)" ||
    die "base revision $base_ref has no merge base with HEAD"
  mapfile -t "$commits_var" \
    < <(git rev-list --reverse --topo-order "$found_merge_base..HEAD")
  printf -v "$merge_base_var" '%s' "$found_merge_base"
}

review_commits() {
  local base_ref="$1"
  shift
  local commits=("$@")
  local failed=0
  local commit short subject_file violations_file subject

  printf 'Reviewing %s commit(s) in %s..HEAD\n' "${#commits[@]}" "$base_ref" >&2

  if ((${#commits[@]} == 0)); then
    printf 'OK: no branch commits found.\n'
    return 0
  fi

  for commit in "${commits[@]}"; do
    short="$(git rev-parse --short "$commit")"
    subject_file="$TMP_DIR/review-subject-$commit"
    violations_file="$TMP_DIR/review-violations-$commit"
    inspect_commit "$commit" "$violations_file" "$subject_file"
    subject="$(cat "$subject_file")"

    if [[ -s "$violations_file" ]]; then
      failed=1
      printf 'FAIL %s %s\n' "$short" "$subject"
      sed 's/^/  - /' "$violations_file"
    else
      printf 'OK   %s %s\n' "$short" "$subject"
    fi
  done

  return "$failed"
}

ensure_rewrite_preconditions() {
  git symbolic-ref --quiet --short HEAD > /dev/null ||
    die "$COMMAND requires a checked-out branch, not detached HEAD"

  git diff --quiet ||
    die "$COMMAND requires no unstaged tracked changes"
  git diff --cached --quiet ||
    die "$COMMAND requires no staged changes"
}

ensure_supported_commit_headers() {
  local commit short line header

  for commit in "$@"; do
    short="$(git rev-parse --short "$commit")"

    while IFS= read -r line; do
      [[ -n "$line" ]] || break
      [[ "$line" != ' '* ]] || continue
      header="${line%% *}"

      case "$header" in
        tree | parent | author | committer) ;;
        *)
          die "commit $short has unsupported '$header' metadata; history was not rewritten"
          ;;
      esac
    done < <(git cat-file commit "$commit")
  done
}

precompute_messages() {
  local failed=0
  local changed=0
  local commit message_file out_file short rc

  mkdir -p "$TMP_DIR/messages"

  for commit in "$@"; do
    short="$(git rev-parse --short "$commit")"
    message_file="$TMP_DIR/original-message-$commit"
    out_file="$TMP_DIR/messages/$commit"
    extract_commit_message "$commit" "$message_file"

    case "$COMMAND" in
      fix-messages)
        set +e
        sanitize_message "$message_file" "$out_file"
        rc=$?
        set -e

        case "$rc" in
          0) ;;
          1)
            failed=1
            printf 'Cannot derive a non-author one-line subject for %s\n' "$short" >&2
            ;;
          2)
            failed=1
            printf 'Subject for %s is longer than %s; rerun with --truncate-long or amend manually\n' \
              "$short" "$MAX_SUBJECT_LENGTH" >&2
            ;;
          3)
            failed=1
            printf 'First non-empty line for %s is an author/trailer line; amend manually\n' \
              "$short" >&2
            ;;
          *)
            failed=1
            printf 'Unexpected sanitizer failure for %s\n' "$short" >&2
            ;;
        esac
        ;;
      add-prefix)
        add_prefix_to_message "$message_file" "$out_file"
        ;;
      *)
        die "command does not rewrite messages: $COMMAND"
        ;;
    esac

    if [[ -f "$out_file" ]] && ! cmp -s "$message_file" "$out_file"; then
      ((changed += 1))
    fi
  done

  MESSAGES_CHANGED="$changed"
  return "$failed"
}

read_commit_header() {
  local commit="$1"
  local header="$2"

  git cat-file commit "$commit" | sed -n "/^$/q; /^$header /p"
}

verify_created_commit() {
  local old_commit="$1"
  local new_commit="$2"
  local expected_parents="$3"
  local actual_parents generated_message

  [[ "$(read_commit_header "$old_commit" tree)" == "$(read_commit_header "$new_commit" tree)" ]] ||
    die "tree changed while rewriting $old_commit"
  [[ "$(read_commit_header "$old_commit" author)" == "$(read_commit_header "$new_commit" author)" ]] ||
    die "author metadata changed while rewriting $old_commit"
  [[ "$(read_commit_header "$old_commit" committer)" == "$(read_commit_header "$new_commit" committer)" ]] ||
    die "committer metadata changed while rewriting $old_commit"

  actual_parents="$(git show -s --format=%P "$new_commit")"
  [[ "$actual_parents" == "$expected_parents" ]] ||
    die "parent topology changed while rewriting $old_commit"

  generated_message="$TMP_DIR/generated-message-$new_commit"
  extract_commit_message "$new_commit" "$generated_message"
  cmp -s "$TMP_DIR/messages/$old_commit" "$generated_message" ||
    die "message changed unexpectedly while rewriting $old_commit"
}

create_backup_branch() {
  local current_branch="$1"
  local original_head="$2"
  local safe_branch timestamp base_name backup_branch suffix=1

  safe_branch="$(printf '%s' "$current_branch" | tr -c 'A-Za-z0-9._-' '-')"
  timestamp="$(date +%Y%m%d%H%M%S)"
  base_name="backup/git-history-${safe_branch}-${timestamp}"
  backup_branch="$base_name"

  while git show-ref --verify --quiet "refs/heads/$backup_branch"; do
    backup_branch="${base_name}-${suffix}"
    ((suffix += 1))
  done

  git branch "$backup_branch" "$original_head"
  printf '%s\n' "$backup_branch"
}

rewrite_commits() {
  local current_branch="$1"
  shift
  local commits=("$@")
  local original_head backup_branch rewritten=0
  local commit tree parents parent mapped_parent mapped_parents new_commit new_head
  local author_name author_email author_date committer_name committer_email committer_date
  local -a parent_args

  original_head="$(git rev-parse HEAD)"
  mkdir -p "$TMP_DIR/map"

  for commit in "${commits[@]}"; do
    tree="$(git show -s --format=%T "$commit")"
    parents="$(git show -s --format=%P "$commit")"
    parent_args=()
    mapped_parents=""

    for parent in $parents; do
      if [[ -f "$TMP_DIR/map/$parent" ]]; then
        mapped_parent="$(cat "$TMP_DIR/map/$parent")"
      else
        mapped_parent="$parent"
      fi
      parent_args+=("-p" "$mapped_parent")
      if [[ -n "$mapped_parents" ]]; then
        mapped_parents+=" "
      fi
      mapped_parents+="$mapped_parent"
    done

    author_name="$(git show -s --format=%an "$commit")"
    author_email="$(git show -s --format=%ae "$commit")"
    author_date="$(git show -s --format=%aI "$commit")"
    committer_name="$(git show -s --format=%cn "$commit")"
    committer_email="$(git show -s --format=%ce "$commit")"
    committer_date="$(git show -s --format=%cI "$commit")"

    new_commit="$(
      GIT_AUTHOR_NAME="$author_name" \
        GIT_AUTHOR_EMAIL="$author_email" \
        GIT_AUTHOR_DATE="$author_date" \
        GIT_COMMITTER_NAME="$committer_name" \
        GIT_COMMITTER_EMAIL="$committer_email" \
        GIT_COMMITTER_DATE="$committer_date" \
        git commit-tree "$tree" "${parent_args[@]}" -F "$TMP_DIR/messages/$commit"
    )"

    verify_created_commit "$commit" "$new_commit" "$mapped_parents"
    printf '%s\n' "$new_commit" > "$TMP_DIR/map/$commit"
    if [[ "$new_commit" != "$commit" ]]; then
      ((rewritten += 1))
    fi
  done

  [[ -f "$TMP_DIR/map/$original_head" ]] ||
    die "could not map the original branch head"
  new_head="$(cat "$TMP_DIR/map/$original_head")"
  backup_branch="$(create_backup_branch "$current_branch" "$original_head")"
  git update-ref "refs/heads/$current_branch" "$new_head" "$original_head"

  printf 'Changed %s message(s); rewrote %s commit object(s).\n' \
    "$MESSAGES_CHANGED" "$rewritten"
  printf 'Backup branch: %s\n' "$backup_branch"
}

verify_prefixes() {
  local commit message_file subject

  for commit in "$@"; do
    message_file="$TMP_DIR/prefix-verification-$commit"
    extract_commit_message "$commit" "$message_file"
    subject=""
    IFS= read -r subject < "$message_file" || true
    [[ "$subject" == "$MESSAGE_PREFIX"* ]] ||
      die "prefix verification failed for $commit"
  done

  printf 'OK: all %s selected commit message(s) start with the prefix.\n' "$#"
}

main() {
  local git_root base_ref merge_base current_branch
  local -a commits new_commits

  parse_args "$@"

  git rev-parse --is-inside-work-tree > /dev/null 2>&1 ||
    die "not inside a git worktree"
  git_root="$(git rev-parse --show-toplevel)"
  cd "$git_root"

  TMP_DIR="$(mktemp -d)"
  base_ref="$(resolve_base_ref)"
  load_branch_commits "$base_ref" commits merge_base

  printf 'Base: %s\n' "$base_ref" >&2
  printf 'Merge base: %s\n' "$merge_base" >&2

  case "$COMMAND" in
    review)
      review_commits "$base_ref" "${commits[@]}"
      ;;
    fix-messages | add-prefix)
      if ((${#commits[@]} == 0)); then
        printf 'OK: no branch commits found.\n'
        exit 0
      fi
      precompute_messages "${commits[@]}" ||
        die "not rewriting history because some commits need manual input"

      if ((MESSAGES_CHANGED == 0)); then
        printf 'OK: no commit messages need to change.\n'
        exit 0
      fi

      ensure_rewrite_preconditions
      ensure_supported_commit_headers "${commits[@]}"
      current_branch="$(git symbolic-ref --quiet --short HEAD)"
      rewrite_commits "$current_branch" "${commits[@]}"
      load_branch_commits "$base_ref" new_commits merge_base
      if [[ "$COMMAND" == "fix-messages" ]]; then
        review_commits "$base_ref" "${new_commits[@]}"
      else
        verify_prefixes "${new_commits[@]}"
      fi
      ;;
    *)
      die "unknown command: $COMMAND"
      ;;
  esac
}

main "$@"
