#!/usr/bin/env bash

_exit_error() {
  echo "ERROR: $*"
  exit 1
}

_arg0() {
  if [ -n "${NIX_CLEANUP_ARG0:-}" ]; then
    printf '%s\n' "$NIX_CLEANUP_ARG0"
    return
  fi

  printf '%s\n' "${0##*/}"
}

_default_cron_command() {
  printf '%s\n' "nix-cleanup --quick --gc --yes --jobs 4"
}

_flake_commit() {
  local commit="${NIX_CLEANUP_FLAKE_COMMIT:-__NIX_CLEANUP_FLAKE_COMMIT__}"

  if [ "$commit" = "__NIX_CLEANUP_FLAKE_COMMIT__" ]; then
    if command -v git > /dev/null 2>&1; then
      commit=$(git rev-parse --short=12 HEAD 2> /dev/null || true)
    else
      commit=""
    fi
  fi

  if [ -z "$commit" ]; then
    commit="unknown"
  fi

  printf '%s\n' "$commit"
}

_help() {
  cat << EOF
nix-cleanup - clean dead nix store paths safely
Flake commit: $(_flake_commit)

Usage:
  $(_arg0) [--yes] [--jobs N] [--quick] [--no-gc|--gc] --system
  $(_arg0) [--yes] [--jobs N] [--quick] [--no-gc|--gc] --older-than 30d
  $(_arg0) [--yes] [--jobs N] [--quick] [--no-gc|--gc] flake-pkg-name
  $(_arg0) [--yes] [--jobs N] [--quick] [--no-gc|--gc] /nix/store/path ...
  $(_arg0) [--yes] [--jobs N] --gc-only
  $(_arg0) --add-cron [COMMAND_OR_CRON_ENTRY]
  $(_arg0) help | -h | --help

Options:
  -y, --yes
      Skip deletion confirmation prompts.
  --system
      Clean all currently dead nix-store paths discovered from /nix/store.
  --older-than <duration>
      Clean dead store paths older than the provided duration.
      Format: <number>d (example: 30d).
  --quick
      One-pass fast cleanup. Deletes dead paths once and skips retry waves.
      Defaults to --system and --no-gc unless target/gc mode is specified.
  --jobs <N>
      Parallel worker count for path filtering and deletion.
      Default: auto (between 4 and 32 based on CPU count).
  --no-gc
      Skip final 'nix-collect-garbage -d'.
  --gc
      Force final 'nix-collect-garbage -d' (overrides --quick default).
  --gc-only
      Run only 'nix-collect-garbage -d'.
  --add-cron <command-or-cron-entry>
      Add an entry to root's crontab (sudo required).
      Full cron entries are installed as-is.
      Plain commands are stored as: @daily <command>.
      Default command when omitted: $(_default_cron_command)
  -h, --help
      Show this help text.

Arguments:
  flake-pkg-name
      Clean everything related to one flake package.
  /nix/store/path ...
      Clean one or more explicit nix store paths.

Notes:
  - Pick exactly one target selector: --system, --older-than, --gc-only,
    a package name, or one/more /nix/store/path values.
  - --quick is safe-by-construction: only dead paths are targeted.
  - --quick defaults to --system and --no-gc when not explicitly set.

Examples:
  $(_arg0) --older-than 30d --quick
  $(_arg0) --quick
  $(_arg0) --system --jobs 16
  $(_arg0) --quick --gc
  $(_arg0) hello --no-gc
  $(_arg0) /nix/store/hash-a /nix/store/hash-b --quick
  $(_arg0) --gc-only
  $(_arg0) --add-cron
  $(_arg0) --add-cron "$(_default_cron_command)"
EOF
}

_count_lines() {
  local file=$1

  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi

  awk 'END { print NR + 0 }' "$file"
}

_print_first_lines() {
  local file=$1
  local limit=${2:-20}

  awk -v limit="$limit" 'NR <= limit { print }' "$file"
}

_now_epoch() {
  date +%s
}

_dedupe_file_inplace() {
  local file=$1
  local tmp

  tmp=$(mktemp)
  awk 'NF && !seen[$0]++' "$file" > "$tmp"
  mv "$tmp" "$file"
}

_print_preview() {
  local label=$1
  local file=$2
  local count

  count=$(_count_lines "$file")
  if [ "$count" -eq 0 ]; then
    return
  fi

  echo "$label (${count}):"
  _print_first_lines "$file" 20
  if [ "$count" -gt 20 ]; then
    echo "... and $((count - 20)) more"
  fi
}

_confirm_deletion() {
  local count=$1
  local reply

  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  read -r -p "Delete ${count} dead path(s)? (y/N): " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 1
  fi
}

_ensure_sudo_session() {
  if [ "$SUDO_READY" -eq 1 ]; then
    return 0
  fi

  if ! command -v sudo > /dev/null 2>&1; then
    _exit_error "package required for cleanup operations: sudo"
  fi

  sudo -v || _exit_error "sudo authentication failed"
  SUDO_READY=1
}

_cpu_count() {
  local count

  count=$(getconf _NPROCESSORS_ONLN 2> /dev/null || true)
  if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
    echo "$count"
    return
  fi

  echo "4"
}

_default_jobs() {
  local cpu
  local jobs

  cpu=$(_cpu_count)
  jobs=$cpu

  if [ "$jobs" -lt 4 ]; then
    jobs=4
  fi

  if [ "$jobs" -gt 32 ]; then
    jobs=32
  fi

  echo "$jobs"
}

_duration_to_days() {
  local duration=$1

  if [[ "$duration" =~ ^([0-9]+)d$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

_list_dead_paths() {
  local output_file=$1

  : > "$output_file"
  _ensure_sudo_session
  # shellcheck disable=SC2024
  if ! sudo -H "$NIX_STORE_BIN" --gc --print-dead > "$output_file"; then
    _exit_error "failed to query dead store paths"
  fi

  _dedupe_file_inplace "$output_file"
}

_classify_paths_against_dead() {
  local candidates_file=$1
  local dead_file=$2
  local deletable_file=$3
  local alive_file=$4

  : > "$deletable_file"
  : > "$alive_file"

  awk -v deletable="$deletable_file" -v alive="$alive_file" '
    NR == FNR {
      if (NF) {
        dead[$0] = 1
      }
      next
    }
    NF && !seen[$0]++ {
      ordered[++count] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        path = ordered[i]
        if (path in dead) {
          print path >> deletable
        } else {
          print path >> alive
        }
      }
    }
  ' "$dead_file" "$candidates_file"
}

_collect_existing_paths() {
  local input_file=$1
  local output_file=$2

  : > "$output_file"
  if [ ! -s "$input_file" ]; then
    return
  fi

  xargs -r -n 256 -P "$JOBS" find -maxdepth 0 -print < "$input_file" > "$output_file" 2> /dev/null || true
  _dedupe_file_inplace "$output_file"
}

_delete_batch() {
  local input_file=$1
  local chunk_size=$2
  local log_file=$3

  : > "$log_file"
  xargs -r -n "$chunk_size" -P "$JOBS" sudo -H "$NIX_STORE_BIN" --delete < "$input_file" > "$log_file" 2>&1 || true
}

DELETE_RESULT_DELETED=0
DELETE_RESULT_UNRESOLVED=0
DELETE_RESULT_UNRESOLVED_FILE=""

_delete_quick() {
  local deletable_file=$1
  local alive_file=$2
  local pending_count
  local log_file
  local remaining_file
  local remaining_count
  local dead_snapshot
  local retry_dead
  local retry_alive

  DELETE_RESULT_DELETED=0
  DELETE_RESULT_UNRESOLVED=0
  DELETE_RESULT_UNRESOLVED_FILE=""

  pending_count=$(_count_lines "$deletable_file")
  if [ "$pending_count" -eq 0 ]; then
    return
  fi

  _ensure_sudo_session

  log_file=$(mktemp)
  _delete_batch "$deletable_file" "$DELETE_CHUNK_SIZE" "$log_file"

  remaining_file=$(mktemp)
  _collect_existing_paths "$deletable_file" "$remaining_file"
  remaining_count=$(_count_lines "$remaining_file")
  DELETE_RESULT_DELETED=$((pending_count - remaining_count))

  if [ "$remaining_count" -gt 0 ]; then
    dead_snapshot=$(mktemp)
    retry_dead=$(mktemp)
    retry_alive=$(mktemp)

    _list_dead_paths "$dead_snapshot"
    _classify_paths_against_dead "$remaining_file" "$dead_snapshot" "$retry_dead" "$retry_alive"
    cat "$retry_alive" >> "$alive_file"
    _dedupe_file_inplace "$alive_file"

    DELETE_RESULT_UNRESOLVED=$(_count_lines "$retry_dead")
    if [ "$DELETE_RESULT_UNRESOLVED" -gt 0 ]; then
      DELETE_RESULT_UNRESOLVED_FILE=$(mktemp)
      cp "$retry_dead" "$DELETE_RESULT_UNRESOLVED_FILE"
    fi

    rm -f "$dead_snapshot" "$retry_dead" "$retry_alive"
  fi

  if [ -s "$log_file" ] && [ "$DELETE_RESULT_UNRESOLVED" -gt 0 ]; then
    echo "Delete output (first 20 lines):"
    _print_first_lines "$log_file" 20
  fi

  rm -f "$remaining_file" "$log_file"
}

_delete_iterative() {
  local deletable_file=$1
  local alive_file=$2
  local pending_file
  local wave
  local chunk
  local no_progress
  local pending_count
  local log_file
  local remaining_file
  local remaining_count
  local deleted_this
  local dead_snapshot
  local retry_dead
  local retry_alive
  local retry_count

  DELETE_RESULT_DELETED=0
  DELETE_RESULT_UNRESOLVED=0
  DELETE_RESULT_UNRESOLVED_FILE=""

  pending_file=$(mktemp)
  cp "$deletable_file" "$pending_file"

  wave=1
  chunk=$DELETE_CHUNK_SIZE
  no_progress=0

  _ensure_sudo_session

  while :; do
    pending_count=$(_count_lines "$pending_file")
    if [ "$pending_count" -eq 0 ]; then
      break
    fi

    if [ "$wave" -gt "$MAX_DELETE_WAVES" ]; then
      echo "Reached max delete waves (${MAX_DELETE_WAVES}); stopping retries."
      break
    fi

    echo "Deletion wave ${wave}: ${pending_count} path(s), jobs=${JOBS}, chunk=${chunk}."

    log_file=$(mktemp)
    _delete_batch "$pending_file" "$chunk" "$log_file"

    remaining_file=$(mktemp)
    _collect_existing_paths "$pending_file" "$remaining_file"
    remaining_count=$(_count_lines "$remaining_file")
    deleted_this=$((pending_count - remaining_count))
    DELETE_RESULT_DELETED=$((DELETE_RESULT_DELETED + deleted_this))

    if [ "$remaining_count" -eq 0 ]; then
      rm -f "$log_file" "$remaining_file"
      : > "$pending_file"
      break
    fi

    dead_snapshot=$(mktemp)
    retry_dead=$(mktemp)
    retry_alive=$(mktemp)

    _list_dead_paths "$dead_snapshot"
    _classify_paths_against_dead "$remaining_file" "$dead_snapshot" "$retry_dead" "$retry_alive"
    cat "$retry_alive" >> "$alive_file"
    _dedupe_file_inplace "$alive_file"

    retry_count=$(_count_lines "$retry_dead")

    rm -f "$dead_snapshot" "$remaining_file" "$retry_alive"

    if [ "$retry_count" -eq 0 ]; then
      rm -f "$log_file" "$retry_dead"
      : > "$pending_file"
      break
    fi

    if [ "$deleted_this" -eq 0 ]; then
      if [ "$chunk" -gt 1 ]; then
        chunk=1
        echo "No progress in wave ${wave}; retrying unresolved paths one-by-one."
      else
        no_progress=$((no_progress + 1))
      fi
    else
      no_progress=0
    fi

    rm -f "$pending_file" "$log_file"
    pending_file="$retry_dead"

    if [ "$no_progress" -ge 1 ]; then
      echo "No progress after one-by-one retries; stopping."
      break
    fi

    wave=$((wave + 1))
  done

  DELETE_RESULT_UNRESOLVED=$(_count_lines "$pending_file")
  if [ "$DELETE_RESULT_UNRESOLVED" -gt 0 ]; then
    DELETE_RESULT_UNRESOLVED_FILE=$(mktemp)
    cp "$pending_file" "$DELETE_RESULT_UNRESOLVED_FILE"
  fi

  rm -f "$pending_file"
}

_run_gc() {
  _ensure_sudo_session
  sudo -H "$NIX_COLLECT_GARBAGE_BIN" -d
}

_candidates_system() {
  local output_file=$1

  echo "Discovering candidates from /nix/store..."
  find /nix/store -mindepth 1 -maxdepth 1 -print > "$output_file"
  _dedupe_file_inplace "$output_file"
}

_candidates_older_than() {
  local older_than=$1
  local output_file=$2
  local days
  local dead_file

  if ! days=$(_duration_to_days "$older_than"); then
    _exit_error "--older-than expects the format <number>d (example: 30d)"
  fi

  dead_file=$(mktemp)
  _list_dead_paths "$dead_file"

  : > "$output_file"
  if [ -s "$dead_file" ]; then
    echo "Discovering dead candidates older than ${older_than}..."
    xargs -r -n 64 -P "$JOBS" find -maxdepth 0 -mtime +"$days" -print < "$dead_file" > "$output_file" 2> /dev/null || true
    _dedupe_file_inplace "$output_file"
  fi

  rm -f "$dead_file"
}

_candidates_store_paths() {
  local output_file=$1
  shift

  printf '%s\n' "$@" | awk 'NF && !seen[$0]++' > "$output_file"
}

_candidates_package() {
  local package_name=$1
  local output_file=$2
  local store_path
  local referrers_file

  store_path=$("$NIX_BIN" path-info ".#$package_name" 2> /dev/null || true)
  if [ -z "$store_path" ]; then
    _exit_error "package not found: $package_name"
  fi

  referrers_file=$(mktemp)
  if ! "$NIX_STORE_BIN" --query --referrers-closure "$store_path" > "$referrers_file"; then
    rm -f "$referrers_file"
    _exit_error "store path not found: $store_path"
  fi

  {
    printf '%s\n' "$store_path"
    cat "$referrers_file"
  } | awk 'NF && !seen[$0]++' > "$output_file"

  rm -f "$referrers_file"
}

_run_cleanup_pipeline() {
  local candidates_file=$1
  local discovery_seconds=$2
  local total_start
  local total_end
  local classify_start
  local classify_end
  local delete_start
  local delete_end
  local gc_start
  local gc_end
  local gc_seconds
  local classify_seconds
  local delete_seconds
  local total_seconds
  local candidate_count
  local dead_snapshot
  local deletable_file
  local alive_file
  local alive_count
  local deletable_count

  total_start=$(_now_epoch)
  gc_seconds=0

  candidate_count=$(_count_lines "$candidates_file")
  echo "Found ${candidate_count} candidate path(s)."

  if [ "$candidate_count" -eq 0 ]; then
    if [ "$RUN_GC" -eq 1 ]; then
      gc_start=$(_now_epoch)
      _run_gc
      gc_end=$(_now_epoch)
      gc_seconds=$((gc_end - gc_start))
    fi

    total_end=$(_now_epoch)
    total_seconds=$((total_end - total_start))

    echo "No matching nix-store paths found."
    echo "Summary: candidates=0 alive_skipped=0 deleted=0 unresolved=0"
    echo "Timing (s): discovery=${discovery_seconds} classify=0 delete=0 gc=${gc_seconds} total=${total_seconds}"
    return 0
  fi

  dead_snapshot=$(mktemp)
  deletable_file=$(mktemp)
  alive_file=$(mktemp)

  classify_start=$(_now_epoch)
  _list_dead_paths "$dead_snapshot"
  _classify_paths_against_dead "$candidates_file" "$dead_snapshot" "$deletable_file" "$alive_file"
  classify_end=$(_now_epoch)
  classify_seconds=$((classify_end - classify_start))

  alive_count=$(_count_lines "$alive_file")
  deletable_count=$(_count_lines "$deletable_file")

  if [ "$alive_count" -gt 0 ]; then
    _print_preview "Skipping paths that are still alive" "$alive_file"
  fi

  if [ "$deletable_count" -eq 0 ]; then
    echo "No deletable (dead) nix-store paths found."

    if [ "$RUN_GC" -eq 1 ]; then
      gc_start=$(_now_epoch)
      _run_gc
      gc_end=$(_now_epoch)
      gc_seconds=$((gc_end - gc_start))
    fi

    total_end=$(_now_epoch)
    total_seconds=$((total_end - total_start))

    echo "Summary: candidates=${candidate_count} alive_skipped=${alive_count} deleted=0 unresolved=0"
    echo "Timing (s): discovery=${discovery_seconds} classify=${classify_seconds} delete=0 gc=${gc_seconds} total=${total_seconds}"

    rm -f "$dead_snapshot" "$deletable_file" "$alive_file"
    return 0
  fi

  _print_preview "Dead paths targeted for deletion" "$deletable_file"

  if [ "$QUICK_MODE" -eq 1 ]; then
    echo "Quick mode enabled: one-pass deletion, no retry waves."
  fi

  _confirm_deletion "$deletable_count"

  delete_start=$(_now_epoch)
  if [ "$QUICK_MODE" -eq 1 ]; then
    _delete_quick "$deletable_file" "$alive_file"
  else
    _delete_iterative "$deletable_file" "$alive_file"
  fi
  delete_end=$(_now_epoch)
  delete_seconds=$((delete_end - delete_start))

  _dedupe_file_inplace "$alive_file"
  alive_count=$(_count_lines "$alive_file")

  if [ "$DELETE_RESULT_UNRESOLVED" -gt 0 ]; then
    _print_preview "Unresolved dead paths (skipped)" "$DELETE_RESULT_UNRESOLVED_FILE"
  fi

  if [ "$RUN_GC" -eq 1 ]; then
    gc_start=$(_now_epoch)
    _run_gc
    gc_end=$(_now_epoch)
    gc_seconds=$((gc_end - gc_start))
  fi

  total_end=$(_now_epoch)
  total_seconds=$((total_end - total_start))

  echo "Deleted ${DELETE_RESULT_DELETED} path(s)."
  echo "Summary: candidates=${candidate_count} alive_skipped=${alive_count} deleted=${DELETE_RESULT_DELETED} unresolved=${DELETE_RESULT_UNRESOLVED}"
  echo "Timing (s): discovery=${discovery_seconds} classify=${classify_seconds} delete=${delete_seconds} gc=${gc_seconds} total=${total_seconds}"

  rm -f "$dead_snapshot" "$deletable_file" "$alive_file"
  if [ -n "$DELETE_RESULT_UNRESOLVED_FILE" ] && [ -f "$DELETE_RESULT_UNRESOLVED_FILE" ]; then
    rm -f "$DELETE_RESULT_UNRESOLVED_FILE"
  fi
}

_all_are_store_paths() {
  local value

  for value in "$@"; do
    if [[ "$value" != /nix/store/* ]]; then
      return 1
    fi
  done

  return 0
}

_valid_cron_entry() {
  local cron_entry=$1
  local field1
  local field2
  local field3
  local field4
  local field5
  local command
  local minute_re='^[0-9*/,-]+$'
  local hour_re='^[0-9*/,-]+$'
  local day_of_month_re='^[0-9*/,-]+$'
  local month_re='^[0-9A-Za-z*/,-]+$'
  local day_of_week_re='^[0-9A-Za-z*/,#-]+$'

  if [[ "$cron_entry" =~ ^@[[:alnum:]_-]+[[:space:]]+.+$ ]]; then
    return 0
  fi

  read -r field1 field2 field3 field4 field5 command <<< "$cron_entry"
  if [ -z "$field1" ] || [ -z "$field2" ] || [ -z "$field3" ] || [ -z "$field4" ] || [ -z "$field5" ] || [ -z "$command" ]; then
    return 1
  fi

  if ! [[ "$field1" =~ $minute_re ]]; then
    return 1
  fi

  if ! [[ "$field2" =~ $hour_re ]]; then
    return 1
  fi

  if ! [[ "$field3" =~ $day_of_month_re ]]; then
    return 1
  fi

  if ! [[ "$field4" =~ $month_re ]]; then
    return 1
  fi

  if ! [[ "$field5" =~ $day_of_week_re ]]; then
    return 1
  fi

  return 0
}

_normalize_cron_entry() {
  local value=$1

  if [ -z "$value" ]; then
    return 1
  fi

  if _valid_cron_entry "$value"; then
    printf '%s\n' "$value"
    return 0
  fi

  printf '@daily %s\n' "$value"
  return 0
}

_add_cron_entry() {
  local value=$1
  local cron_entry
  local existing_crontab_file
  local merged_crontab_file

  if ! command -v crontab > /dev/null 2>&1; then
    _exit_error "package required for --add-cron: crontab"
  fi

  if ! cron_entry=$(_normalize_cron_entry "$value"); then
    _exit_error "--add-cron requires a command or cron entry"
  fi

  _ensure_sudo_session

  existing_crontab_file=$(mktemp)
  merged_crontab_file=$(mktemp)

  # shellcheck disable=SC2024
  if ! sudo -H crontab -l > "$existing_crontab_file" 2> /dev/null; then
    : > "$existing_crontab_file"
  fi

  if grep -Fqx -- "$cron_entry" "$existing_crontab_file"; then
    echo "Cron entry already exists in root crontab."
    rm -f "$existing_crontab_file" "$merged_crontab_file"
    return 0
  fi

  cp "$existing_crontab_file" "$merged_crontab_file"
  printf '%s\n' "$cron_entry" >> "$merged_crontab_file"

  if ! sudo -H crontab "$merged_crontab_file"; then
    rm -f "$existing_crontab_file" "$merged_crontab_file"
    _exit_error "failed to install cron entry"
  fi

  rm -f "$existing_crontab_file" "$merged_crontab_file"
  echo "Installed cron entry in root crontab:"
  echo "$cron_entry"
}

_required_packages=(
  "nix"
  "nix-store"
  "nix-collect-garbage"
  "git"
  "crontab"
  "find"
  "xargs"
  "mktemp"
  "awk"
  "grep"
  "cp"
  "mv"
  "rm"
  "cat"
  "sleep"
  "date"
)

for req in "${_required_packages[@]}"; do
  if ! command -v "$req" > /dev/null 2>&1; then
    _exit_error "package required: $req"
  fi
done

NIX_BIN=$(command -v nix)
NIX_STORE_BIN=$(command -v nix-store)
NIX_COLLECT_GARBAGE_BIN=$(command -v nix-collect-garbage)

CLEANUP_SYSTEM=0
OLDER_THAN=""
ADD_CRON_ENTRY=""
ASSUME_YES=0
POSITIONAL_ARGS=()
SUDO_READY=0
QUICK_MODE=0
RUN_GC=1
GC_ONLY=0
GC_MODE_SET=0
JOBS=""
DELETE_CHUNK_SIZE=128
MAX_DELETE_WAVES=5
QUICK_DEFAULTED_SYSTEM=0
QUICK_DEFAULTED_NO_GC=0

if [ "${1:-}" = "help" ]; then
  _help
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      _help
      exit 0
      ;;
    -y | --yes)
      ASSUME_YES=1
      shift
      ;;
    --system)
      CLEANUP_SYSTEM=1
      shift
      ;;
    --older-than)
      if [ -z "${2:-}" ]; then
        _exit_error "--older-than requires a value (example: 30d)"
      fi
      OLDER_THAN="$2"
      shift 2
      ;;
    --older-than=*)
      OLDER_THAN="${1#*=}"
      shift
      ;;
    --quick)
      QUICK_MODE=1
      shift
      ;;
    --jobs)
      if [ -z "${2:-}" ]; then
        _exit_error "--jobs requires a value"
      fi
      JOBS="$2"
      shift 2
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      shift
      ;;
    --no-gc)
      RUN_GC=0
      GC_MODE_SET=1
      shift
      ;;
    --gc)
      RUN_GC=1
      GC_MODE_SET=1
      shift
      ;;
    --gc-only)
      GC_ONLY=1
      shift
      ;;
    --add-cron)
      shift
      if [ $# -eq 0 ]; then
        ADD_CRON_ENTRY=$(_default_cron_command)
        break
      fi
      ADD_CRON_ENTRY="$*"
      break
      ;;
    --add-cron=*)
      ADD_CRON_ENTRY="${1#*=}"
      if [ -z "$ADD_CRON_ENTRY" ]; then
        ADD_CRON_ENTRY=$(_default_cron_command)
      fi
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      _exit_error "unknown option: $1"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -n "$JOBS" ] && [[ ! "$JOBS" =~ ^[0-9]+$ || "$JOBS" -lt 1 ]]; then
  _exit_error "--jobs expects a positive integer"
fi

if [ -z "$JOBS" ]; then
  JOBS=$(_default_jobs)
fi

if [ "$GC_ONLY" -eq 1 ] && [ "$RUN_GC" -eq 0 ]; then
  _exit_error "--gc-only cannot be combined with --no-gc"
fi

if [ -n "$ADD_CRON_ENTRY" ] && { [ "$CLEANUP_SYSTEM" -eq 1 ] || [ -n "$OLDER_THAN" ] || [ "$GC_ONLY" -eq 1 ] || [ "${#POSITIONAL_ARGS[@]}" -gt 0 ] || [ "$QUICK_MODE" -eq 1 ] || [ "$GC_MODE_SET" -eq 1 ]; }; then
  _exit_error "--add-cron cannot be combined with cleanup options/arguments"
fi

selector_count=0
if [ "$CLEANUP_SYSTEM" -eq 1 ]; then
  selector_count=$((selector_count + 1))
fi
if [ -n "$OLDER_THAN" ]; then
  selector_count=$((selector_count + 1))
fi
if [ "$GC_ONLY" -eq 1 ]; then
  selector_count=$((selector_count + 1))
fi
if [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
  selector_count=$((selector_count + 1))
fi

if [ "$selector_count" -gt 1 ]; then
  _exit_error "pick exactly one target selector: --system, --older-than, --gc-only, package name, or /nix/store/path values"
fi

if [ "$GC_ONLY" -eq 1 ] && [ "$QUICK_MODE" -eq 1 ]; then
  _exit_error "--quick cannot be combined with --gc-only"
fi

if [ "$QUICK_MODE" -eq 1 ]; then
  if [ "$selector_count" -eq 0 ]; then
    CLEANUP_SYSTEM=1
    selector_count=1
    QUICK_DEFAULTED_SYSTEM=1
  fi

  if [ "$GC_ONLY" -eq 0 ] && [ "$GC_MODE_SET" -eq 0 ]; then
    RUN_GC=0
    QUICK_DEFAULTED_NO_GC=1
  fi
fi

if [ "$selector_count" -eq 0 ] && [ -z "$ADD_CRON_ENTRY" ]; then
  _help
  exit 1
fi

if [ -n "$ADD_CRON_ENTRY" ]; then
  _add_cron_entry "$ADD_CRON_ENTRY"
  exit $?
fi

if [ "$GC_ONLY" -eq 1 ]; then
  _run_gc
  echo "Garbage collection complete."
  exit 0
fi

discovery_start=$(_now_epoch)
candidates_file=$(mktemp)

if [ "$QUICK_DEFAULTED_SYSTEM" -eq 1 ]; then
  echo "Quick mode default: using --system target."
fi
if [ "$QUICK_DEFAULTED_NO_GC" -eq 1 ]; then
  echo "Quick mode default: skipping final GC (--no-gc)."
fi

if [ -n "$OLDER_THAN" ]; then
  _candidates_older_than "$OLDER_THAN" "$candidates_file"
elif [ "$CLEANUP_SYSTEM" -eq 1 ]; then
  _candidates_system "$candidates_file"
else
  if _all_are_store_paths "${POSITIONAL_ARGS[@]}"; then
    _candidates_store_paths "$candidates_file" "${POSITIONAL_ARGS[@]}"
  else
    if [ "${#POSITIONAL_ARGS[@]}" -gt 1 ]; then
      rm -f "$candidates_file"
      _exit_error "expected one flake package name or one/more /nix/store/path values"
    fi
    _candidates_package "${POSITIONAL_ARGS[0]}" "$candidates_file"
  fi
fi

discovery_end=$(_now_epoch)
discovery_seconds=$((discovery_end - discovery_start))

_run_cleanup_pipeline "$candidates_file" "$discovery_seconds"
status=$?
rm -f "$candidates_file"
exit "$status"
