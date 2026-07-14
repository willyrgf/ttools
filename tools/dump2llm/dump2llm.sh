#!/usr/bin/env bash
set -euo pipefail

_usage() {
  cat << EOF
Usage: ${0##*/} [--ignore <path[,path...]>] <inputs...>

Inputs can be:
  Git repository URLs
  Local directories
  Individual files
  Glob patterns (*.js, **/*.py, etc.)
  A mix of the above

Examples:
  ${0##*/} README.md
  ${0##*/} docs/*.md
  ${0##*/} '**/*.py'
  ${0##*/} --ignore 'docs/drafts,*.generated' docs/**/*.md
EOF
}

_error() {
  printf 'error: %s\n' "$*" >&2
}

declare -a ignore_patterns=()
declare -a inputs=()

while (($# > 0)); do
  case "$1" in
    -h | --help)
      _usage
      exit 0
      ;;
    --ignore)
      if (($# < 2)) || [[ -z "$2" ]]; then
        _error "--ignore requires a non-empty value"
        exit 2
      fi

      declare -a ignore_values=()
      IFS=',' read -r -a ignore_values <<< "$2"
      for ignore_value in "${ignore_values[@]}"; do
        if [[ -z "$ignore_value" ]]; then
          _error "--ignore values must not be empty"
          exit 2
        fi
        ignore_patterns+=("$ignore_value")
      done
      shift 2
      ;;
    --)
      shift
      inputs=("$@")
      break
      ;;
    -*)
      _error "unknown option: $1"
      exit 2
      ;;
    *)
      inputs=("$@")
      break
      ;;
  esac
done

if ((${#inputs[@]} == 0)); then
  _error "at least one input is required"
  exit 2
fi

_detect_input_type() {
  local input=$1

  if [[ -d "$input" ]]; then
    printf '%s\n' directory
  elif [[ -f "$input" ]]; then
    printf '%s\n' file
  elif [[ "$input" =~ ^(https?|ssh|file):// ]] ||
    [[ "$input" =~ ^git@[^:]+: ]] ||
    [[ "$input" == */*.git ]]; then
    printf '%s\n' git_url
  elif [[ "$input" == *"**/"* || "$input" == *"**" ]]; then
    printf '%s\n' recursive_glob
  elif [[ "$input" == *"*"* || "$input" == *"?"* || "$input" == *"["* ]]; then
    printf '%s\n' single_glob
  else
    printf '%s\n' file
  fi
}

_append_find_files() {
  local search_root=$1
  shift

  while IFS= read -r -d '' file; do
    all_files+=("$file")
  done < <(
    find -- "$search_root" "$@" -type f -print0 2> /dev/null | sort -z
  )
}

_collect_files_from_recursive_glob() {
  local pattern=$1
  local marker='**/'
  local prefix="${pattern%%"$marker"*}"
  local suffix="${pattern#*"$marker"}"
  local search_root="${prefix%/}"

  [[ -n "$search_root" ]] || search_root=.
  [[ -d "$search_root" ]] || return 0

  if [[ "$suffix" == */* ]]; then
    _append_find_files "$search_root" -path "*/$suffix"
  else
    _append_find_files "$search_root" -name "$suffix"
  fi
}

_collect_files_from_single_glob() {
  local pattern=$1
  local search_root=.
  local file_pattern=$pattern

  if [[ "$pattern" == */* ]]; then
    search_root=${pattern%/*}
    file_pattern=${pattern##*/}
    [[ -n "$search_root" ]] || search_root=/
  fi

  [[ -d "$search_root" ]] || return 0
  _append_find_files "$search_root" -maxdepth 1 -name "$file_pattern"
}

_collect_files_from_directory() {
  local directory=$1
  local root

  if root=$(git -C "$directory" rev-parse --show-toplevel 2> /dev/null); then
    root=$(realpath -- "$root")
    local absolute_directory
    absolute_directory=$(realpath -- "$directory")
    local pathspec=.

    if [[ "$absolute_directory" != "$root" ]]; then
      pathspec=${absolute_directory#"$root"/}
    fi

    while IFS= read -r -d '' file; do
      all_files+=("$root/$file")
    done < <(
      git -C "$root" ls-files --cached --others --exclude-standard -z -- "$pathspec" |
        sort -z
    )
  else
    while IFS= read -r -d '' file; do
      all_files+=("$file")
    done < <(
      find -- "$directory" \( -type d -name .git -prune \) -o -type f -print0 2> /dev/null |
        sort -z
    )
  fi
}

_is_text() {
  [[ -f "$1" ]] && grep -Iq . -- "$1" > /dev/null 2>&1
}

_is_ignored() {
  local path=$1
  local pattern

  for pattern in "${ignore_patterns[@]}"; do
    if [[ "$path" == "$pattern" || "$path" == "$pattern/"* ]]; then
      return 0
    fi
    # shellcheck disable=SC2053 # The ignore value is intentionally a glob.
    if [[ "$path" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

_dump_file() {
  local display_path=$1
  local file=$2

  printf '\n<<< FILE: %s >>>\n' "$display_path"
  cat -- "$file"
  printf '\n<<< END OF %s >>>\n' "$display_path"
}

_cleanup_temp_dirs() {
  local temp_dir

  for temp_dir in "${temp_dirs[@]}"; do
    [[ -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
  done
}

declare -a all_files=()
declare -a temp_dirs=()
trap _cleanup_temp_dirs EXIT

for input in "${inputs[@]}"; do
  case "$(_detect_input_type "$input")" in
    git_url)
      work_dir=$(mktemp -d)
      temp_dirs+=("$work_dir")
      if ! GIT_TERMINAL_PROMPT=0 git clone --depth=1 "$input" "$work_dir"; then
        _error "failed to clone Git input: $input"
        exit 1
      fi
      _collect_files_from_directory "$work_dir"
      ;;
    directory)
      _collect_files_from_directory "$input"
      ;;
    file)
      if [[ -f "$input" ]]; then
        all_files+=("$input")
      else
        _error "input is not a regular file: $input"
        exit 2
      fi
      ;;
    recursive_glob)
      _collect_files_from_recursive_glob "$input"
      ;;
    single_glob)
      _collect_files_from_single_glob "$input"
      ;;
  esac
done

working_directory=$(pwd -P)
declare -a processed_files=()

for file in "${all_files[@]}"; do
  absolute_path=$(realpath -- "$file")

  already_processed=false
  for processed_file in "${processed_files[@]}"; do
    if [[ "$processed_file" == "$absolute_path" ]]; then
      already_processed=true
      break
    fi
  done
  [[ "$already_processed" == true ]] && continue
  processed_files+=("$absolute_path")

  if [[ "$absolute_path" == "$working_directory/"* ]]; then
    display_path=${absolute_path#"$working_directory"/}
  else
    display_path=$file
  fi

  _is_text "$file" || continue
  _is_ignored "$display_path" && continue
  _dump_file "$display_path" "$file"
done
