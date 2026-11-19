# shellcheck shell=bash
# desk/bin/lib/bindings.sh — the account-to-queue registry (issue #2183).
# Sourced, never executed. Bash 3.2 compatible (macOS /bin/bash).
#
# Each Claude account (identified by its config directory) is explicitly bound
# to one named queue (a Postgres schema). The registry lives OUTSIDE any account
# profile, so copying a profile's settings.json never carries a binding along.
#
#   File   ${HUMAN_QUEUE_BINDINGS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/human-queue/bindings.tsv}
#          directory mode 700, file mode 600, rewritten atomically.
#   Row    <config dir><TAB><name><TAB><schema>   (one row per account)
#          Lines that are empty or start with # are ignored. Names and schemas
#          only: the connection URL is never stored here.
#
# Account identity is the config directory spelled as Claude Code sees it:
# CLAUDE_CONFIG_DIR when set and non-empty, else $HOME/.claude, with ~ expanded,
# made absolute against the working directory, and trailing slashes removed.
# It is LEXICAL on purpose: no symlink resolution and no case folding, because
# Claude Code derives a credential realm from the spelling, so two spellings are
# two accounts. An unbound alias is refused (fail closed), never mapped.
# capture.py mirrors these rules exactly; desk/tests/bindings-offline.test.sh
# checks that both agree.
#
# HUMAN_QUEUE_SCHEMA is honored by the desk entry points only when it names a
# throwaway test schema (hq_test_ prefix); see hqb_test_schema.
#
# Return codes for hqb_lookup: 0 bound (name and schema on stdout, tab
# separated), 3 not bound, 7 the registry is unreadable or malformed (reason in
# HQB_REASON). Nothing here prints a diagnostic; callers decide. Do not call
# these from $(...): the globals would be lost in the subshell.

export HQB_REASON="" HQB_NAME="" HQB_SCHEMA=""

# hqb_file — the registry path.
hqb_file() {
  printf '%s\n' "${HUMAN_QUEUE_BINDINGS_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/human-queue/bindings.tsv}"
}

# hqb_config_dir — the resolved config directory, or a non-zero status with
# HQB_REASON set when neither CLAUDE_CONFIG_DIR nor HOME gives one.
hqb_config_dir() {
  local d="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$d" ]; then
    if [ -z "${HOME:-}" ]; then
      HQB_REASON="neither CLAUDE_CONFIG_DIR nor HOME is set"
      return 1
    fi
    d="$HOME/.claude"
  fi
  local tilde='~'
  case "$d" in
    "$tilde") d="${HOME:-}" ;;
    "$tilde"/*) d="${HOME:-}/${d#"$tilde"/}" ;;
  esac
  case "$d" in
    /*) ;;
    *) d="$PWD/$d" ;;
  esac
  while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do
    d="${d%/}"
  done
  printf '%s\n' "$d"
}

# hqb_valid_schema S — a queue schema: the same rule as common.sh's hq_schema.
hqb_valid_schema() {
  case "$1" in
    ''|pg_*|[!a-z_]*|*[!a-z0-9_]*) return 1 ;;
  esac
  [ "${#1}" -le 63 ]
}

# hqb_valid_name N — an account name: letters, digits, dot, underscore, hyphen,
# starting with a letter or digit, at most 64 characters.
hqb_valid_name() {
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# hqb_test_schema — prints HUMAN_QUEUE_SCHEMA and returns 0 only when it names a
# throwaway test schema (hq_test_ prefix, valid identifier). Any other value is
# ignored by the desk entry points, so an env entry cannot select a queue.
hqb_test_schema() {
  local s="${HUMAN_QUEUE_SCHEMA:-}"
  case "$s" in
    hq_test_*) ;;
    *) return 1 ;;
  esac
  hqb_valid_schema "$s" || return 1
  printf '%s\n' "$s"
}

# hqb_test_binding — prints HUMAN_QUEUE_BINDING (the caller's binding name for
# the queue owner check, issue #2184) only when the test schema seam is in use
# and the name carries the hq_test_ prefix; any other value prints nothing.
# So the seam can never name a real account, and an unnamed test call keeps the
# pre-#2184 behavior on an unstamped schema.
hqb_test_binding() {
  local n="${HUMAN_QUEUE_BINDING:-}"
  case "$n" in
    hq_test_*) ;;
    *) return 0 ;;
  esac
  hqb_valid_name "$n" && printf '%s\n' "$n"
  return 0
}

# hqb_lookup DIR — the row bound to DIR (see return codes above). On 0, sets
# HQB_NAME and HQB_SCHEMA. Not run in a subshell, so HQB_REASON survives. A
# duplicate row for DIR, or any malformed row, is a corrupt registry: fail closed.
hqb_lookup() {
  local want="$1" file dir name schema rest line n=0
  HQB_NAME=""
  HQB_SCHEMA=""
  file=$(hqb_file)
  if [ ! -e "$file" ]; then
    # A missing file is "unbound" only when its directory can be searched; an
    # existing but unsearchable directory hides the file from stat, so the
    # lookup cannot tell it apart from absence and must report unreadable.
    dir=$(dirname "$file")
    if [ -d "$dir" ] && [ ! -x "$dir" ]; then
      HQB_REASON="the queue bindings directory is not searchable, so the file cannot be checked"
      return 7
    fi
    return 3
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    HQB_REASON="the queue bindings file is not a readable regular file"
    return 7
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # Exactly three non-empty tab-separated fields, and validated.
    case "$line" in
      *$'\t'*$'\t'*$'\t'*) HQB_REASON="the queue bindings file has a malformed row"; return 7 ;;
    esac
    dir="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    case "$rest" in
      *$'\t'*) name="${rest%%$'\t'*}"; schema="${rest#*$'\t'}" ;;
      *) HQB_REASON="the queue bindings file has a malformed row"; return 7 ;;
    esac
    case "$dir" in
      /*) ;;
      *) HQB_REASON="the queue bindings file has a row that is not an absolute path"; return 7 ;;
    esac
    if ! hqb_valid_name "$name" || ! hqb_valid_schema "$schema"; then
      HQB_REASON="the queue bindings file has a row with an invalid name or queue"
      return 7
    fi
    if [ "$dir" = "$want" ]; then
      n=$((n + 1))
      HQB_NAME="$name"
      HQB_SCHEMA="$schema"
    fi
  done < "$file"
  if [ "$n" -gt 1 ]; then
    HQB_REASON="the queue bindings file lists this account more than once"
    return 7
  fi
  if [ "$n" -eq 0 ]; then
    return 3
  fi
  return 0
}

# hqb_store DIR NAME SCHEMA — replaces any row for DIR with the new one. Keeps
# every other line (comments included), writes a temp file in the same
# directory, and renames it over the registry. Returns 7 on any failure.
hqb_store() {
  local file dir tmp line
  file=$(hqb_file)
  dir=$(dirname "$file")
  if ! (umask 077 && mkdir -p "$dir") 2>/dev/null; then
    HQB_REASON="cannot create $dir"
    return 7
  fi
  # Fail closed: a directory this account cannot secure is not one to write
  # the registry into.
  if ! chmod 700 "$dir" 2>/dev/null; then
    HQB_REASON="cannot make $dir owner-only"
    return 7
  fi
  tmp=$(mktemp "$dir/bindings.XXXXXX" 2>/dev/null) || { HQB_REASON="cannot create a temp file in $dir"; return 7; }
  {
    if [ -f "$file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "$1"$'\t'*) ;;
          *) printf '%s\n' "$line" ;;
        esac
      done < "$file"
    fi
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  } > "$tmp" || { rm -f "$tmp"; HQB_REASON="cannot write the queue bindings file"; return 7; }
  chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; HQB_REASON="cannot replace the queue bindings file"; return 7; }
}
