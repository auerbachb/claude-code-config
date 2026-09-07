#!/usr/bin/env bash
# ai-quotas-setup.sh — Register AI subscription accounts and their isolated
# per-account login profiles (issue #1666).
# catalog: token-measurement — Register AI subscription accounts (`claude`/`codex`/`cursor`) and their isolated per-account login profiles in `~/.claude/ai-quotas.json`, and report which ones are currently logged in — labels and paths only, never a credential value
#
# PURPOSE
#   The owner runs several premium AI coding subscriptions side by side and
#   drains them in rotation. Reading where each account stands starts with
#   knowing which accounts exist and being able to reach each one's live
#   login. This script owns that registry, and nothing else: it records
#   accounts, creates one isolated profile directory per account, launches the
#   provider's OWN login flow against that profile, and reports which accounts
#   currently hold a credential.
#
#   DISPLAY / CONFIG ONLY. Nothing here may gate dispatch, pause work, or feed
#   `credit-budget.sh`. Quota and spend authority stays where
#   `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" puts it:
#   Anthropic's own in-app UI and upstream harness signals. Schema, re-login
#   commands, and the increment boundary: `.claude/reference/ai-quotas.md`.
#
#   NO CREDENTIAL VALUE IS EVER READ, PRINTED, OR STORED. The config holds a
#   provider, a label, a profile directory, and — on macOS — the NAME of the
#   Keychain item the provider's own tool created. Every reader borrows the
#   provider tool's live credential at run time instead.
#
# USAGE
#   ai-quotas-setup.sh [list] [--json]
#   ai-quotas-setup.sh add <provider> <label> [--no-login]
#   ai-quotas-setup.sh remove <label> [<provider>]
#   ai-quotas-setup.sh relogin <label> [<provider>]
#   ai-quotas-setup.sh --help | -h
#
# ACTIONS
#   list      Default when no action is given. Prints one row per registered
#             account with its status: `ok` (a credential is present),
#             `needs-login` (none visible — run `relogin`), or
#             `not-yet-supported` (cursor, until increment 3). On a readable
#             config it exits 0 whatever the statuses say — listing is a
#             report, never a gate. The one non-zero list is exit 5, when the
#             config itself is unreadable, unparseable, or written by a
#             different schema major: a broken tool, not a verdict.
#   add       Register <label> for <provider>, create its profile directory,
#             and run that provider's interactive login against it. The login
#             is the provider's own (magic link, SSO, CAPTCHA); this script
#             launches it and waits — it never types or reads credentials.
#             Refuses a (provider, label) pair that is already registered.
#   remove    Drop an account from the config. The profile directory is LEFT
#             ON DISK and its path is printed: removing a registry row must
#             never destroy a working login. Delete it yourself if you mean to.
#   relogin   Re-run the provider's login against an already-registered
#             account's existing profile directory, then re-verify.
#
# PROVIDERS
#   claude    Per-account CLAUDE_CONFIG_DIR, logged in by running `claude`
#             against it (the documented flow; `claude auth login` does not
#             exist, and `setup-token` prints a credential instead of storing
#             one). Credential lands in the macOS
#             Keychain (service `Claude Code-credentials-<suffix>`, whose
#             suffix this script learns by observing which item the login
#             created — it is never derived or guessed) or, on other
#             platforms, in `<profile_dir>/.credentials.json`.
#   codex     Per-account CODEX_HOME. Credential lands in
#             `<profile_dir>/auth.json`.
#   cursor    Browser-profile slot only. Increment 3 performs the login; until
#             then `list` reports `not-yet-supported` and `relogin` refuses.
#
# LAYOUT
#   Config    ~/.claude/ai-quotas.json                 (mode 600)
#   Profiles  ~/.claude/ai-quotas/profiles/<label>/<provider>/   (mode 700)
#   Both live under ~/.claude/, never in a worktree (hook-storage rule).
#
# ENVIRONMENT (overrides; the defaults are what you want)
#   AI_QUOTAS_CONFIG        Config file path.
#   AI_QUOTAS_PROFILE_ROOT  Profile directory root.
#   AI_QUOTAS_CLAUDE_BIN    Path to the `claude` CLI.
#   AI_QUOTAS_CODEX_BIN     Path to the `codex` CLI.
#   AI_QUOTAS_SECURITY_BIN  Path to macOS `security(1)`.
#   AI_QUOTAS_CLAUDE_LOGIN_ARGS
#                           Extra argv for the `claude` login invocation
#                           (default: none — the documented flow is a bare
#                           `claude` against the profile's CLAUDE_CONFIG_DIR).
#                           Set it to `/login` on a CLI version where that
#                           shortcut is preferred.
#   AI_QUOTAS_PLATFORM      Platform name (default: `uname -s`). `Darwin`
#                           selects the Keychain probe.
#   The last four exist so the test suite can exercise every path against
#   stubs without touching a real login, a real keychain, or a real account.
#
# OUTPUT
#   stdout: the account table, or a JSON array with `--json`.
#   stderr: one-line diagnostics.
#
# EXIT STATUS
#   0   Action completed (list always exits 0).
#   1   Login ran but produced no credential this script can see — or produced
#       an ambiguous one (two keychain items appeared across it, so the item
#       belonging to this account cannot be told apart). Nothing recorded.
#       Re-run, or use `add --no-login` to reserve the slot anyway.
#   3   Usage error: bad action, provider, or label; already-registered pair;
#       an ambiguous label that matches more than one provider.
#   4   No account matches the given label (remove / relogin).
#   5   Dependency or write failure: `jq` missing, config unreadable,
#       unparseable, or written by a different schema major (never rewritten),
#       profile directory or config write failed.
#   6   The provider's login CLI could not be found. The exact command to run
#       by hand is printed.
#   7   Config write lock unavailable (timeout) or broken mid-update; the
#       config is unchanged.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   - bash 3.2+, jq
#   - state-lock.sh (sibling library) for the config read-modify-write lock
#   - the provider's own CLI, only for `add` / `relogin`

set -euo pipefail
# Telemetry logs the ACTION ONLY, never the full argument list. Every other
# script logs "$*", but here the arguments carry the account label — the
# owner's subscription email — and script-usage.log is a long-lived plaintext
# file. The action word is all the usage report needs.
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${1:-list}" \
  2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

SELF_NAME="$(basename "$0")"
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# HOME is only needed for the defaults. An unset HOME under `set -u` would
# otherwise abort with bash's own unbound-variable message, which names a
# variable rather than the problem; both paths can also be given explicitly.
_HOME="${HOME:-}"
if [[ -z "$_HOME" ]] && { [[ -z "${AI_QUOTAS_CONFIG:-}" ]] || [[ -z "${AI_QUOTAS_PROFILE_ROOT:-}" ]]; }; then
  echo "${SELF_NAME}: HOME is unset — set it, or pass both AI_QUOTAS_CONFIG and AI_QUOTAS_PROFILE_ROOT" >&2
  exit 5
fi

CONFIG_FILE="${AI_QUOTAS_CONFIG:-${_HOME}/.claude/ai-quotas.json}"
PROFILE_ROOT="${AI_QUOTAS_PROFILE_ROOT:-${_HOME}/.claude/ai-quotas/profiles}"
SCHEMA_VERSION="1.0"
PLATFORM="${AI_QUOTAS_PLATFORM:-$(uname -s 2>/dev/null || echo unknown)}"
SECURITY_BIN="${AI_QUOTAS_SECURITY_BIN:-security}"
KEYCHAIN_SERVICE_PREFIX="Claude Code-credentials"

# --- help / usage ------------------------------------------------------------

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "${SELF_NAME}: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

die() { # <exit-code> <message>
  echo "${SELF_NAME}: $2" >&2
  exit "$1"
}

# --- shared write lock -------------------------------------------------------
# The config is a read-modify-write surface like session-state.json, so it
# borrows the same portable advisory lock rather than inventing a second one.

if [[ ! -f "$SELF_DIR/state-lock.sh" || ! -r "$SELF_DIR/state-lock.sh" ]]; then
  die 5 "missing sibling library: $SELF_DIR/state-lock.sh"
fi
# shellcheck source=./state-lock.sh
if ! source "$SELF_DIR/state-lock.sh"; then
  die 5 "failed to load $SELF_DIR/state-lock.sh"
fi

# --- arg parsing -------------------------------------------------------------

ACTION=""
JSON=0
NO_LOGIN=0
ARG_PROVIDER=""
ARG_LABEL=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json)    JSON=1; shift ;;
    --no-login) NO_LOGIN=1; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*) die_usage "unknown flag: $1" ;;
    *)  POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
  ACTION="list"
else
  ACTION="${POSITIONAL[0]}"
fi

case "$ACTION" in
  list)
    [[ ${#POSITIONAL[@]} -le 1 ]] || die_usage "list takes no arguments"
    ;;
  add)
    [[ ${#POSITIONAL[@]} -eq 3 ]] || die_usage "add requires <provider> <label>"
    ARG_PROVIDER="${POSITIONAL[1]}"
    ARG_LABEL="${POSITIONAL[2]}"
    ;;
  remove|relogin)
    [[ ${#POSITIONAL[@]} -ge 2 && ${#POSITIONAL[@]} -le 3 ]] \
      || die_usage "$ACTION requires <label> [<provider>]"
    ARG_LABEL="${POSITIONAL[1]}"
    if [[ ${#POSITIONAL[@]} -eq 3 ]]; then
      ARG_PROVIDER="${POSITIONAL[2]}"
    fi
    ;;
  *)
    die_usage "unknown action: $ACTION (expected list, add, remove, relogin)"
    ;;
esac

if [[ $JSON -eq 1 && "$ACTION" != "list" ]]; then
  die_usage "--json applies to list only"
fi
if [[ $NO_LOGIN -eq 1 && "$ACTION" != "add" ]]; then
  die_usage "--no-login applies to add only"
fi

# --- validation --------------------------------------------------------------

valid_provider() { # <provider>
  case "$1" in claude|codex|cursor) return 0 ;; *) return 1 ;; esac
}

# A label becomes a directory name, so it is restricted rather than escaped:
# no slash, no leading dot, nothing that could climb out of PROFILE_ROOT.
valid_label() { # <label>
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] && [[ ${#1} -le 128 ]]
}

if [[ -n "$ARG_PROVIDER" ]]; then
  valid_provider "$ARG_PROVIDER" \
    || die_usage "unknown provider: $ARG_PROVIDER (expected claude, codex, or cursor)"
fi
if [[ -n "$ARG_LABEL" ]]; then
  valid_label "$ARG_LABEL" \
    || die_usage "invalid label: $ARG_LABEL (allowed: letters, digits, and . _ @ + - starting with a letter or digit, max 128 chars)"
fi

command -v jq >/dev/null 2>&1 || die 5 "'jq' not found on PATH"

# --- config read / write -----------------------------------------------------

EMPTY_CONFIG="{\"schema_version\":\"${SCHEMA_VERSION}\",\"accounts\":[]}"

read_config() {
  if [[ ! -e "$CONFIG_FILE" ]]; then
    printf '%s' "$EMPTY_CONFIG"
    return 0
  fi
  [[ -r "$CONFIG_FILE" ]] || die 5 "config not readable: $CONFIG_FILE"
  local raw
  raw="$(cat "$CONFIG_FILE")" || die 5 "could not read config: $CONFIG_FILE"
  # An unparseable config is never overwritten — the user's registry is not
  # ours to discard on a parse error.
  # Every account is checked for SHAPE, not just the envelope. A row missing
  # `profile_dir` reads back as the string "null" through `jq -r`, and that
  # string then reaches `mkdir -p` and `chmod 700 "$(dirname …)"` — which
  # creates `./null` and chmods the CURRENT DIRECTORY to 700. Refusing the
  # config is the same answer this function already gives an unparseable one.
  # The check stays deliberately structural: it requires the three fields to
  # be non-empty strings and does NOT enumerate provider values, so a `1.x`
  # config written by a newer tool that knows a fourth provider is still
  # accepted, exactly as the major-version rule below promises. `credential_ref`
  # is optional (only macOS claude accounts carry one), but WHEN PRESENT its
  # shape is checked too: `relogin` reads `.credential_ref.service` through
  # `jq -r`, and a `credential_ref` that is a string rather than an object makes
  # jq abort with "Cannot index string" — which under `set -e` surfaces as jq's
  # error instead of this script's, telling the user nothing about their config.
  # `added_at` is deliberately NOT required: nothing reads it, and demanding it
  # would refuse a `1.x` config from a newer tool that stopped writing it.
  printf '%s' "$raw" | jq -e '
      type == "object"
      and (.accounts | type == "array")
      and (.accounts | all(
            type == "object"
            and (.provider    | type == "string" and length > 0)
            and (.label       | type == "string" and length > 0)
            and (.profile_dir | type == "string" and length > 0)
            and ((has("credential_ref") | not)
                 or (.credential_ref
                     | type == "object"
                       and (.service | type == "string" and length > 0)))))' >/dev/null 2>&1 \
    || die 5 "config is not valid ai-quotas JSON — every account needs a non-empty string provider, label, and profile_dir, and any credential_ref must be an object with a non-empty string service — refusing to touch it: $CONFIG_FILE"
  # Forward compatibility is by MAJOR version: a `1.x` config written by a
  # newer tool may carry fields this one does not know, and preserving them is
  # a jq-level property of every write below. A different major means the
  # shape itself changed, and rewriting it here would silently drop whatever
  # it holds — so refuse instead.
  local found_major
  found_major="$(printf '%s' "$raw" | jq -r '(.schema_version // "1.0") | tostring | split(".")[0]')"
  if [[ "$found_major" != "${SCHEMA_VERSION%%.*}" ]]; then
    die 5 "config schema_version is v${found_major}.x but this tool writes v${SCHEMA_VERSION%%.*}.x — refusing to rewrite $CONFIG_FILE"
  fi
  printf '%s' "$raw"
}

# Callers hold the write lock; the install goes through state_lock_commit so a
# lock broken mid-update refuses to publish instead of racing another writer.
write_config() { # <json>
  local json="$1" dir tmp rc=0
  dir="$(dirname "$CONFIG_FILE")"
  mkdir -p "$dir" || die 5 "could not create config directory: $dir"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 \
    || die 5 "refusing to write malformed config JSON"
  tmp="$(mktemp "${dir}/.ai-quotas.XXXXXX")" || die 5 "could not create temp file in $dir"
  # The mode is set on the temp file, before any content lands in it, so the
  # config is never briefly world-readable between creation and chmod.
  chmod 600 "$tmp" || { rm -f "$tmp"; die 5 "could not chmod temp config"; }
  printf '%s\n' "$json" | jq -S . > "$tmp" || { rm -f "$tmp"; die 5 "could not serialize config"; }
  state_lock_commit "$tmp" "$CONFIG_FILE" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq "${STATE_LOCK_EXIT_TIMEOUT:-6}" ]]; then
      die 7 "the config write lock was broken mid-update; $CONFIG_FILE is unchanged — retry"
    fi
    die 5 "could not install config: $CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE" || die 5 "could not chmod 600 $CONFIG_FILE"
}

# --- keychain observation (macOS, claude only) -------------------------------
# The Keychain service name Claude Code uses carries a suffix derived from
# CLAUDE_CONFIG_DIR by an undocumented function. This script never derives it:
# it lists the service NAMES before and after a login and records the one that
# appeared. A name is not a secret, and `security` is never asked for a value
# (`-w` is never passed), so nothing readable here is a credential.

keychain_claude_services() {
  [[ "$PLATFORM" == "Darwin" ]] || return 0
  command -v "$SECURITY_BIN" >/dev/null 2>&1 || return 0
  "$SECURITY_BIN" dump-keychain 2>/dev/null \
    | sed -n "s/^[[:space:]]*\"svce\"<blob>=\"\(${KEYCHAIN_SERVICE_PREFIX}[^\"]*\)\"[[:space:]]*$/\1/p" \
    | LC_ALL=C sort -u \
    || true
}

# The observed service name is also remembered NEXT TO the profile, because a
# login against a profile that already has a Keychain item rewrites that item
# instead of creating one — so the before/after diff is empty and there is
# nothing to observe. That is the ordinary shape of re-registering a label
# whose profile `remove` deliberately left on disk. The sidecar holds a NAME,
# never a value, and it is never trusted on its own: `credential_present`
# still asks the Keychain whether that item exists, so a stale sidecar reports
# needs-login rather than a false ok.
keychain_sidecar_path() { # <profile_dir>
  printf '%s/.keychain-service-%s' "$(dirname "$1")" "$(basename "$1")"
}

# A failed sidecar write is not fatal — the credential itself is already
# verified and the account is genuinely registered — but it is never SILENT.
# The sidecar is the only record of the observed service name, so losing it
# turns a later re-add of this profile (after `remove` left the directory and
# its Keychain item in place) into a fail-closed error with no visible cause.
# Warning here is what makes that later refusal explicable. The file is
# created under `umask 077` BEFORE the name goes into it, so it is never
# briefly group- or world-readable; the chmod that follows tightens a file
# that already existed with a looser mode, and its own failure is reported
# too — the doc promises a mode-600 sidecar, so a silently looser one would
# make that promise false.
remember_keychain_service() { # <profile_dir> <service>
  [[ -n "${2:-}" ]] || return 0
  local f
  f="$(keychain_sidecar_path "$1")"
  if ! ( umask 077; : > "$f" ) 2>/dev/null || ! printf '%s\n' "$2" > "$f" 2>/dev/null; then
    echo "${SELF_NAME}: warning: could not remember the keychain service name at ${f} — the account IS registered, but re-adding this label after a 'remove' will fail closed and need a fresh login." >&2
    return 0
  fi
  chmod 600 "$f" 2>/dev/null ||
    echo "${SELF_NAME}: warning: could not chmod 600 ${f} — it holds a service name, never a credential value, but tighten it by hand." >&2
}

recall_keychain_service() { # <profile_dir>
  local f
  f="$(keychain_sidecar_path "$1")"
  [[ -s "$f" ]] || return 0
  head -n 1 "$f"
}

keychain_service_exists() { # <service>
  [[ "$PLATFORM" == "Darwin" ]] || return 1
  [[ -n "$1" ]] || return 1
  command -v "$SECURITY_BIN" >/dev/null 2>&1 || return 1
  "$SECURITY_BIN" find-generic-password -s "$1" >/dev/null 2>&1
}

# --- provider CLI resolution -------------------------------------------------

provider_bin() { # <provider> -> path on stdout, or empty + exit 1
  local provider="$1" override="" candidate
  local -a candidates=()
  case "$provider" in
    claude)
      override="${AI_QUOTAS_CLAUDE_BIN:-}"
      candidates=(
        "${_HOME}/.claude/local/claude"
        "/opt/homebrew/bin/claude"
        "/usr/local/bin/claude"
      )
      ;;
    codex)
      override="${AI_QUOTAS_CODEX_BIN:-}"
      candidates=(
        "/opt/homebrew/bin/codex"
        "/usr/local/bin/codex"
        "/Applications/ChatGPT.app/Contents/Resources/codex"
      )
      ;;
    *) return 1 ;;
  esac
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || return 1
    printf '%s' "$override"
    return 0
  fi
  if candidate="$(command -v "$provider" 2>/dev/null)" && [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

manual_login_command() { # <provider> <profile_dir>
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR=%q claude %s' "$2" "${AI_QUOTAS_CLAUDE_LOGIN_ARGS:-}" ;;
    codex)  printf 'CODEX_HOME=%q codex login' "$2" ;;
    cursor) printf '(cursor login arrives in increment 3)' ;;
  esac
}

# Runs the provider's own interactive login against this account's profile.
# stdin/stdout/stderr are inherited on purpose: the user completes a magic
# link or SSO flow in the normal way. Returns the login command's exit status.
run_login() { # <provider> <profile_dir>
  local provider="$1" dir="$2" bin
  if ! bin="$(provider_bin "$provider")"; then
    echo "${SELF_NAME}: no '${provider}' CLI found (PATH, override, and known install paths all checked)." >&2
    echo "${SELF_NAME}: install it, or log in by hand with:" >&2
    echo "  $(manual_login_command "$provider" "$dir")" >&2
    exit 6
  fi
  echo "${SELF_NAME}: launching ${provider} login for this profile — complete it in the window/browser it opens."
  case "$provider" in
    claude)
      # The DOCUMENTED way to authenticate a specific CLAUDE_CONFIG_DIR is to
      # run `claude` against it with no arguments: an unauthenticated config
      # dir opens the browser login, and Claude Code persists the credential
      # scoped to that directory. Two rejected alternatives, so nobody
      # "fixes" this back:
      #   * `claude auth login` — no such subcommand exists.
      #   * `claude setup-token` — real, but it PRINTS a one-year token to
      #     stdout instead of persisting it. This tool must never have a
      #     credential value pass through it.
      # `/login` as an argument is widely used but undocumented, so it is
      # available through AI_QUOTAS_CLAUDE_LOGIN_ARGS rather than hard-coded.
      echo "${SELF_NAME}: when the login finishes, exit the session (/exit or Ctrl-D) to continue."
      local -a claude_args=()
      if [[ -n "${AI_QUOTAS_CLAUDE_LOGIN_ARGS:-}" ]]; then
        # The override is an argument LIST, so it is split on whitespace — but
        # `read -a` is used rather than an unquoted expansion because splitting
        # is wanted and PATHNAME EXPANSION is not: an unquoted `*` or `?` in the
        # value would glob against the current directory and silently hand
        # `claude` an argv nobody wrote. `read` splits and never globs.
        read -r -a claude_args <<< "${AI_QUOTAS_CLAUDE_LOGIN_ARGS}"
      fi
      CLAUDE_CONFIG_DIR="$dir" "$bin" ${claude_args[@]+"${claude_args[@]}"}
      ;;
    codex)  CODEX_HOME="$dir" "$bin" login ;;
  esac
}

# --- credential probe --------------------------------------------------------
# Answers one question — did the provider's own tool leave a credential for
# this profile — by testing for the artifact's PRESENCE. The value is never
# opened.
#
# Sets CRED_DETAIL to a short human note (may be empty). Returns 0 present,
# 1 absent.

CRED_DETAIL=""

credential_present() { # <provider> <profile_dir> <keychain_service|"">
  local provider="$1" dir="$2" service="$3"
  CRED_DETAIL=""
  case "$provider" in
    codex)
      [[ -s "$dir/auth.json" ]] && return 0
      # auth.json is where Codex normally lands, but it is not the only place
      # a logged-in CODEX_HOME can keep its session. Ask the tool itself
      # before calling the account logged out — `login status` answers with an
      # exit code, and its output is discarded so no account detail is
      # printed. Absent CLI just means we fall through to the honest "no".
      local codex_bin
      if codex_bin="$(provider_bin codex)"; then
        if CODEX_HOME="$dir" "$codex_bin" login status >/dev/null 2>&1; then
          return 0
        fi
      fi
      CRED_DETAIL="no auth.json in profile"
      return 1
      ;;
    claude)
      # File store first: it is the whole story off macOS, and on macOS a
      # present file is still a valid credential store.
      [[ -s "$dir/.credentials.json" ]] && return 0
      if [[ "$PLATFORM" == "Darwin" ]]; then
        if [[ -z "$service" ]]; then
          CRED_DETAIL="no keychain item recorded for this profile"
          return 1
        fi
        if ! command -v "$SECURITY_BIN" >/dev/null 2>&1; then
          CRED_DETAIL="security(1) unavailable, cannot see the keychain"
          return 1
        fi
        keychain_service_exists "$service" && return 0
        CRED_DETAIL="recorded keychain item is gone"
        return 1
      fi
      CRED_DETAIL="no .credentials.json in profile"
      return 1
      ;;
    cursor)
      CRED_DETAIL="login arrives in increment 3"
      return 1
      ;;
  esac
  CRED_DETAIL="unknown provider"
  return 1
}

# Both results go into globals and NOTHING onto stdout (Greptile). The status
# used to be printed, which forced every caller to invoke this through
# `$(...)` — a subshell, where the CRED_DETAIL that `credential_present` sets
# is discarded along with it. The caller then read the parent's still-empty
# CRED_DETAIL, so every NOTE column rendered as `-` and every JSON `detail` came
# out empty, hiding exactly the diagnostics this pair exists to surface: a
# missing credential file, an unreachable Keychain, a deleted item. It is the
# same subshell trap `discover_keychain_service` documents above.
ACCOUNT_STATUS=""

account_status() { # <provider> <profile_dir> <keychain_service|"">
  ACCOUNT_STATUS=""
  CRED_DETAIL=""
  if [[ "$1" == "cursor" ]]; then
    CRED_DETAIL="slot reserved; login arrives in increment 3"
    ACCOUNT_STATUS="not-yet-supported"
    return 0
  fi
  if credential_present "$@"; then
    ACCOUNT_STATUS="ok"
  else
    ACCOUNT_STATUS="needs-login"
  fi
}

# --- account lookup ----------------------------------------------------------

# Echoes the indices (0-based, newline separated) of accounts matching
# <label> and optionally <provider>.
match_indices() { # <config-json> <label> <provider|"">
  printf '%s' "$1" | jq -r --arg label "$2" --arg provider "$3" '
    .accounts
    | to_entries
    | map(select(.value.label == $label
                 and ($provider == "" or .value.provider == $provider)))
    | .[].key'
}

resolve_single_index() { # <config-json> <label> <provider|""> -> index on stdout
  local matches count
  matches="$(match_indices "$1" "$2" "$3")"
  count="$(printf '%s' "$matches" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    if [[ -n "$3" ]]; then
      die 4 "no account registered with label '$2' for provider '$3'"
    fi
    die 4 "no account registered with label '$2'"
  fi
  if [[ "$count" -gt 1 ]]; then
    local providers
    providers="$(printf '%s' "$1" | jq -r --arg label "$2" \
      '[.accounts[] | select(.label == $label) | .provider] | join(", ")')"
    die 3 "label '$2' matches more than one account ($providers) — name the provider too"
  fi
  printf '%s' "$matches"
}

# --- profile directory -------------------------------------------------------

profile_dir_for() { # <label> <provider>
  printf '%s/%s/%s' "$PROFILE_ROOT" "$1" "$2"
}

ensure_profile_dir() { # <dir>
  mkdir -p "$PROFILE_ROOT" || die 5 "could not create profile root: $PROFILE_ROOT"
  # The label is already restricted so it cannot climb out of PROFILE_ROOT,
  # but a pre-existing SYMLINK at the label or provider component is a second
  # way out: `mkdir -p` follows it, and the profile — with the credential the
  # login is about to write into it — lands somewhere else entirely. So the
  # containment is checked on the PHYSICAL path (`pwd -P` resolves every
  # link), not on the string. A symlink that stays inside the root is left
  # alone, because it does not move anything out.
  #
  # The check runs BEFORE anything is created (Greptile). Creating the profile
  # first and refusing afterwards still let `mkdir -p` deposit the provider
  # directory at the symlink's external destination — no credential, but a
  # refused operation had already written outside the configured root. A link
  # can only redirect through a component that already exists, so resolving
  # the deepest EXISTING ancestor and re-attaching the components still to be
  # created answers the same question without creating any of them.
  local root_phys probe rest="" phys
  root_phys="$( (cd -P "$PROFILE_ROOT" 2>/dev/null && pwd -P) || true )"
  [[ -n "$root_phys" ]] || die 5 "could not resolve the profile root: $PROFILE_ROOT"
  probe="$1"
  while [[ ! -d "$probe" ]]; do
    rest="$(basename "$probe")${rest:+/$rest}"
    probe="$(dirname "$probe")"
    [[ "$probe" != "/" && "$probe" != "." && "$probe" != "$1" ]] || break
  done
  phys="$( (cd -P "$probe" 2>/dev/null && pwd -P) || true )"
  [[ -n "$phys" ]] || die 5 "could not resolve the profile directory or its root: $1"
  [[ -z "$rest" ]] || phys="$phys/$rest"
  case "$phys" in
    "$root_phys"/*) : ;;
    *) die 5 "profile directory $1 resolves to $phys, outside the profile root $root_phys (a symlink in the path?) — refusing to run a login against it" ;;
  esac

  mkdir -p "$1" || die 5 "could not create profile directory: $1"
  # Re-check what was actually created. The pre-creation check answers the
  # question for the tree as it stood a moment ago; this one answers it for
  # the directory the login is about to be pointed at. Both run before any
  # login, so a redirected profile never receives a credential.
  phys="$( (cd -P "$1" 2>/dev/null && pwd -P) || true )"
  [[ -n "$phys" ]] || die 5 "could not resolve the profile directory or its root: $1"
  case "$phys" in
    "$root_phys"/*) : ;;
    *) die 5 "profile directory $1 resolves to $phys, outside the profile root $root_phys (a symlink in the path?) — refusing to run a login against it" ;;
  esac
  # Tighten the whole chain we create, not just the leaf: a world-readable
  # parent is how a per-account profile stops being isolated.
  chmod 700 "$PROFILE_ROOT" 2>/dev/null || true
  chmod 700 "$(dirname "$1")" || die 5 "could not chmod 700 the profile parent of $1"
  chmod 700 "$1" || die 5 "could not chmod 700 $1"
}

# --- actions -----------------------------------------------------------------

# Discovers which keychain item a just-completed claude login created, by
# comparing the before/after service-name snapshots. Echoes a service name, or
# nothing; it never fabricates or guesses one.
#
# AMBIGUITY IS REFUSED, NOT GUESSED (CodeRabbit, local review). If two logins
# for different accounts overlap, more than one item can appear between this
# run's two snapshots, and picking the first would silently bind an account to
# another account's credential — a wrong answer that looks exactly like a
# right one. The alternative CodeRabbit proposed, a dedicated keychain lock
# held across the login, would hold a lock for the length of an unbounded
# interactive flow (magic link, SSO) — well past the 120s staleness ceiling
# that would then let another writer break it mid-login anyway. Detecting the
# collision and refusing costs nothing and cannot be wrong: the caller reports
# it and the user re-runs the one login on its own.
# Results go into globals, NOT onto stdout: a `$(...)` call would run this in
# a subshell, where the ambiguity flag it sets would be discarded along with
# the subshell and every ambiguous login would silently fall through to the
# ordinary "no credential" path.
NEW_KEYCHAIN_AMBIGUOUS=0
NEW_KEYCHAIN_SERVICE=""

discover_keychain_service() { # <before-list> <after-list>
  NEW_KEYCHAIN_AMBIGUOUS=0
  NEW_KEYCHAIN_SERVICE=""
  [[ "$PLATFORM" == "Darwin" ]] || return 0
  local before_f after_f added count
  before_f="$(mktemp)"; after_f="$(mktemp)"
  printf '%s\n' "$1" | LC_ALL=C sort -u > "$before_f"
  printf '%s\n' "$2" | LC_ALL=C sort -u > "$after_f"
  added="$(LC_ALL=C comm -13 "$before_f" "$after_f" | grep . || true)"
  rm -f "$before_f" "$after_f"
  count="$(printf '%s' "$added" | grep -c . || true)"
  if [[ "$count" -gt 1 ]]; then
    NEW_KEYCHAIN_AMBIGUOUS=1
    return 0
  fi
  NEW_KEYCHAIN_SERVICE="$added"
}

# Chooses which service name this profile's credential_ref should carry after a
# login, given what this profile was already known to use and what appeared in
# the Keychain while the login ran.
#
# A KNOWN item that the Keychain still holds WINS over one that merely appeared
# (Greptile). The keychain-observation note above is the reason: a login against
# a profile that already has an item rewrites that item in place, so OUR login
# contributes nothing to the before/after diff — and anything that did appear
# was created by some other login running at the same time. `discover_keychain_
# service` refuses two or more such items as ambiguous, but exactly one is
# indistinguishable from an ordinary first login, and adopting it would rebind
# this account to another account's credential. `credential_present` cannot
# catch that: the foreign item does exist, so the account would go on reporting
# `ok` while pointing at the wrong credential.
#
# The item that appeared is taken only when this profile has no live item to
# keep — nothing recorded anywhere, or what was recorded is gone from the
# Keychain, which is what re-keying an account actually looks like.
resolve_keychain_service() { # <profile_dir> <recorded-service|""> <appeared-service|"">
  local known="$2"
  [[ -n "$known" ]] || known="$(recall_keychain_service "$1")"
  if [[ -n "$known" ]] && keychain_service_exists "$known"; then
    printf '%s' "$known"
    return 0
  fi
  if [[ -n "$3" ]]; then
    printf '%s' "$3"
    return 0
  fi
  printf '%s' "$known"
}

action_add() {
  local provider="$ARG_PROVIDER" label="$ARG_LABEL"
  local config dir service="" before="" after=""

  config="$(read_config)"
  local existing
  existing="$(match_indices "$config" "$label" "$provider")"
  if [[ -n "$existing" ]]; then
    die 3 "'$label' is already registered for $provider — use 'relogin $label $provider' instead"
  fi

  dir="$(profile_dir_for "$label" "$provider")"
  ensure_profile_dir "$dir"

  if [[ "$provider" == "cursor" ]]; then
    echo "${SELF_NAME}: cursor browser-profile slot reserved at $dir (login arrives in increment 3)."
  elif [[ $NO_LOGIN -eq 1 ]]; then
    echo "${SELF_NAME}: --no-login — slot reserved at $dir; run 'relogin $label $provider' when ready."
  else
    if [[ "$provider" == "claude" ]]; then
      before="$(keychain_claude_services)"
    fi
    if ! run_login "$provider" "$dir"; then
      die 1 "the ${provider} login did not complete; nothing was registered. Re-run, or use 'add ${provider} ${label} --no-login' to reserve the slot."
    fi
    if [[ "$provider" == "claude" ]]; then
      after="$(keychain_claude_services)"
      discover_keychain_service "$before" "$after"
      if [[ "$NEW_KEYCHAIN_AMBIGUOUS" -eq 1 ]]; then
        die 1 "more than one keychain item appeared while this login ran (a concurrent login?), so which one belongs to '${label}' cannot be told apart; nothing was registered. Re-run this add on its own."
      fi
      service="$(resolve_keychain_service "$dir" "" "$NEW_KEYCHAIN_SERVICE")"
    fi
    if ! credential_present "$provider" "$dir" "$service"; then
      die 1 "the ${provider} login finished but left no credential this script can see (${CRED_DETAIL}); nothing was registered. Re-run, or use 'add ${provider} ${label} --no-login' to reserve the slot."
    fi
    if [[ "$provider" == "claude" ]]; then
      remember_keychain_service "$dir" "$service"
    fi
  fi

  local entry now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  entry="$(jq -n \
    --arg provider "$provider" \
    --arg label "$label" \
    --arg profile_dir "$dir" \
    --arg added_at "$now" \
    --arg service "$service" \
    '{provider: $provider, label: $label, profile_dir: $profile_dir, added_at: $added_at}
     + (if $service == "" then {} else {credential_ref: {kind: "macos-keychain", service: $service}} end)')"

  state_lock_acquire "$CONFIG_FILE" || die 7 "timed out waiting for the config write lock"
  config="$(read_config)"
  # Re-check under the lock: a concurrent add of the same pair would otherwise
  # append a duplicate row that every later lookup reports as ambiguous.
  if [[ -n "$(match_indices "$config" "$label" "$provider")" ]]; then
    state_lock_release || true
    die 3 "'$label' was registered for $provider by another process while this login ran"
  fi
  # Seed the version only when absent: a `1.x` config written by a newer tool
  # keeps its own minor, since read_config already accepted it as compatible.
  config="$(printf '%s' "$config" | jq --argjson entry "$entry" \
    --arg schema "$SCHEMA_VERSION" '.schema_version = (.schema_version // $schema) | .accounts += [$entry]')" \
    || { state_lock_release || true; die 5 "could not add the account entry"; }
  write_config "$config"
  state_lock_release || true

  echo "${SELF_NAME}: registered ${provider} account '${label}' (profile: ${dir})."
}

action_remove() {
  local config index entry dir provider
  config="$(read_config)"
  index="$(resolve_single_index "$config" "$ARG_LABEL" "$ARG_PROVIDER")"
  entry="$(printf '%s' "$config" | jq --argjson i "$index" '.accounts[$i]')"
  dir="$(printf '%s' "$entry" | jq -r '.profile_dir')"
  provider="$(printf '%s' "$entry" | jq -r '.provider')"

  state_lock_acquire "$CONFIG_FILE" || die 7 "timed out waiting for the config write lock"
  config="$(read_config)"
  # Re-resolve under the lock: the index read a moment ago may name a
  # different row now, and deleting by a stale index removes the wrong one.
  index="$(match_indices "$config" "$ARG_LABEL" "${ARG_PROVIDER:-$provider}" | head -n 1)"
  if [[ -z "$index" ]]; then
    state_lock_release || true
    die 4 "no account registered with label '$ARG_LABEL' (removed by another process?)"
  fi
  config="$(printf '%s' "$config" | jq --argjson i "$index" 'del(.accounts[$i])')" \
    || { state_lock_release || true; die 5 "could not remove the account entry"; }
  write_config "$config"
  state_lock_release || true

  echo "${SELF_NAME}: removed ${provider} account '${ARG_LABEL}' from the registry."
  echo "${SELF_NAME}: its profile directory was left in place: ${dir}"
}

action_relogin() {
  local config index entry dir provider service="" before="" after=""
  config="$(read_config)"
  index="$(resolve_single_index "$config" "$ARG_LABEL" "$ARG_PROVIDER")"
  entry="$(printf '%s' "$config" | jq --argjson i "$index" '.accounts[$i]')"
  dir="$(printf '%s' "$entry" | jq -r '.profile_dir')"
  provider="$(printf '%s' "$entry" | jq -r '.provider')"
  service="$(printf '%s' "$entry" | jq -r '.credential_ref.service // ""')"

  if [[ "$provider" == "cursor" ]]; then
    die 3 "cursor login arrives in increment 3 — nothing to re-run for '$ARG_LABEL' yet"
  fi

  ensure_profile_dir "$dir"
  if [[ "$provider" == "claude" ]]; then
    before="$(keychain_claude_services)"
  fi
  if ! run_login "$provider" "$dir"; then
    die 1 "the ${provider} login did not complete; '${ARG_LABEL}' is unchanged"
  fi
  if [[ "$provider" == "claude" ]]; then
    after="$(keychain_claude_services)"
    discover_keychain_service "$before" "$after"
    if [[ "$NEW_KEYCHAIN_AMBIGUOUS" -eq 1 ]]; then
      die 1 "more than one keychain item appeared while this login ran (a concurrent login?), so which one belongs to '${ARG_LABEL}' cannot be told apart; '${ARG_LABEL}' is unchanged. Re-run this relogin on its own."
    fi
    service="$(resolve_keychain_service "$dir" "$service" "$NEW_KEYCHAIN_SERVICE")"
  fi
  if ! credential_present "$provider" "$dir" "$service"; then
    die 1 "the ${provider} login finished but left no credential this script can see (${CRED_DETAIL}); '${ARG_LABEL}' is unchanged"
  fi
  if [[ "$provider" == "claude" ]]; then
    remember_keychain_service "$dir" "$service"
  fi

  state_lock_acquire "$CONFIG_FILE" || die 7 "timed out waiting for the config write lock"
  config="$(read_config)"
  index="$(match_indices "$config" "$ARG_LABEL" "$provider" | head -n 1)"
  if [[ -z "$index" ]]; then
    state_lock_release || true
    die 4 "account '$ARG_LABEL' disappeared from the registry while the login ran"
  fi
  config="$(printf '%s' "$config" | jq --argjson i "$index" --arg service "$service" '
    .accounts[$i] = (.accounts[$i]
      + (if $service == "" then {} else {credential_ref: {kind: "macos-keychain", service: $service}} end))')" \
    || { state_lock_release || true; die 5 "could not update the account entry"; }
  write_config "$config"
  state_lock_release || true

  echo "${SELF_NAME}: ${provider} account '${ARG_LABEL}' is logged in again."
}

action_list() {
  local config count
  config="$(read_config)"
  count="$(printf '%s' "$config" | jq '.accounts | length')"

  if [[ "$count" -eq 0 ]]; then
    if [[ $JSON -eq 1 ]]; then
      echo "[]"
    else
      echo "No accounts registered yet."
      echo "Add one with: ${SELF_NAME} add <claude|codex|cursor> <label>"
    fi
    return 0
  fi

  local rows="" json_rows="[]" i provider label dir service status detail
  for (( i = 0; i < count; i++ )); do
    provider="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].provider // ""')"
    label="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].label // ""')"
    dir="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].profile_dir // ""')"
    service="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].credential_ref.service // ""')"
    # Called bare, never through `$(...)`: both results come back in globals.
    account_status "$provider" "$dir" "$service"
    status="$ACCOUNT_STATUS"
    detail="$CRED_DETAIL"
    if [[ $JSON -eq 1 ]]; then
      json_rows="$(printf '%s' "$json_rows" | jq \
        --arg provider "$provider" --arg label "$label" --arg profile_dir "$dir" \
        --arg status "$status" --arg detail "$detail" \
        '. += [{provider: $provider, label: $label, profile_dir: $profile_dir,
                status: $status, detail: $detail}]')"
    else
      rows+="$(printf '%s\t%s\t%s\t%s\t%s' "$provider" "$label" "$status" "${detail:--}" "$dir")"$'\n'
    fi
  done

  if [[ $JSON -eq 1 ]]; then
    printf '%s\n' "$json_rows"
    return 0
  fi

  {
    printf 'PROVIDER\tLABEL\tSTATUS\tNOTE\tPROFILE_DIR\n'
    printf '%s' "$rows"
  } | column -t -s $'\t' 2>/dev/null || {
    printf 'PROVIDER\tLABEL\tSTATUS\tNOTE\tPROFILE_DIR\n'
    printf '%s' "$rows"
  }
  echo
  echo "Display only — never a dispatch or spend gate (.claude/rules/safety.md §Anthropic Quota & Spend Authority)."
}

case "$ACTION" in
  list)    action_list ;;
  add)     action_add ;;
  remove)  action_remove ;;
  relogin) action_relogin ;;
esac
