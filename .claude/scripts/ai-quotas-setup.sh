#!/usr/bin/env bash
# ai-quotas-setup.sh — Register AI subscription accounts and their isolated
# per-account login profiles (issue #1666).
# catalog: token-measurement — Register AI subscription accounts (`claude`/`codex`/`cursor`) and their isolated per-account login profiles in `~/.claude/ai-quotas.json`, name them with short nicknames, install or remove the macOS LaunchAgent that takes one unattended usage reading a day, and report which accounts are currently logged in — labels and paths only, never a credential value
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
#   ai-quotas-setup.sh add <provider> <label> [--nick <name>] [--no-login]
#   ai-quotas-setup.sh nick <label> <name> [<provider>]
#   ai-quotas-setup.sh remove <label> [<provider>]
#   ai-quotas-setup.sh relogin <label> [<provider>]
#   ai-quotas-setup.sh schedule <install|remove|status> [--hour <0-23>]
#   ai-quotas-setup.sh --help | -h
#
# ACTIONS
#   list      Default when no action is given. Prints one row per registered
#             account with its status: `ok` (a credential is present),
#             `needs-login` (none visible — run `relogin`). On a readable
#             config it exits 0 whatever the statuses say — listing is a
#             report, never a gate. The one non-zero list is exit 5, when the
#             config itself is unreadable, unparseable, or written by a
#             different schema major: a broken tool, not a verdict.
#   add       Register <label> for <provider>, create its profile directory,
#             and run that provider's interactive login against it. The login
#             is the provider's own (magic link, SSO, CAPTCHA); this script
#             launches it and waits — it never types or reads credentials.
#             Refuses a (provider, label) pair that is already registered.
#             `--nick <name>` records a short display name in the same step.
#   nick      Set (or clear, with an empty name) an already-registered
#             account's short display name. `/quotas` shows it in place of
#             the label, which is what keeps a five-account table of full
#             subscription emails inside 100 columns.
#   remove    Drop an account from the config. The profile directory is LEFT
#             ON DISK and its path is printed: removing a registry row must
#             never destroy a working login. Delete it yourself if you mean to.
#   relogin   Re-run the provider's login against an already-registered
#             account's existing profile directory, then re-verify.
#   schedule  macOS only (exit 2 elsewhere). Manage the LaunchAgent that takes
#             one unattended usage reading a day, so the history `/quotas`
#             records has no holes on days nobody ran it:
#               install  write ~/Library/LaunchAgents/com.claude.ai-quotas.plist
#                        and load it. Runs `ai-quotas.sh --json --quiet` at
#                        09:00 local (--hour changes it) and once on load,
#                        logging to ~/.claude/ai-quotas/launchd.log.
#               remove   bootout the job and delete the plist.
#               status   report loaded / not loaded, the plist path, and when
#                        the last unattended snapshot was taken.
#             The job is a RECORDER, never a gate: it reads figures and
#             appends them, and nothing in this repo consults them to decide
#             whether work may proceed.
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
#   cursor    Per-account browser profile, logged in by opening a real
#             browser window on it through `lib/ai-quotas-cursor.js`
#             (Playwright). Cursor has no login CLI and no individual usage
#             API, so the saved session IS the credential; it stays inside
#             the profile directory and is never read by this script. A
#             `relogin` MOVES the old profile aside and starts a fresh one
#             rather than layering a second session over it.
#
# LAYOUT
#   Config    ~/.claude/ai-quotas.json                 (mode 600)
#   Profiles  ~/.claude/ai-quotas/profiles/<label>/<provider>/   (mode 700)
#   Both live under ~/.claude/, never in a worktree (hook-storage rule).
#   Agent     ~/Library/LaunchAgents/com.claude.ai-quotas.plist  (mode 644,
#             macOS only, written by `schedule install`)
#   Job log   ~/.claude/ai-quotas/launchd.log
#   History   ~/.claude/ai-quotas-history.jsonl — written by ai-quotas.sh,
#             read here only to answer `schedule status`.
#
# ENVIRONMENT (overrides; the defaults are what you want)
#   AI_QUOTAS_CONFIG        Config file path.
#   AI_QUOTAS_PROFILE_ROOT  Profile directory root.
#   AI_QUOTAS_LAUNCH_AGENT  Path of the LaunchAgent plist `schedule` writes.
#   AI_QUOTAS_LAUNCHCTL_BIN Path to launchctl.
#   AI_QUOTAS_READER_BIN    Path to ai-quotas.sh to put in the plist. Used
#                           EXCLUSIVELY when set, for the same reason
#                           AI_QUOTAS_CHEAPEST_BIN is in the reader: a seam
#                           that falls back to the portable search finds the
#                           repo copy whenever the caller stands in a
#                           checkout, so the "reader unresolvable" path could
#                           never be exercised from the one place the suite
#                           runs.
#   AI_QUOTAS_HISTORY       Snapshot history path, read by `schedule status`.
#   AI_QUOTAS_LAUNCHD_LOG   Path the job's stdout/stderr are directed to.
#   AI_QUOTAS_SCHEDULE_HOUR Default hour for `schedule install` when --hour
#                           is not given (0-23; the built-in default is 9).
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
#   AI_QUOTAS_NODE_BIN      Path to node (the cursor login helper's runtime).
#   AI_QUOTAS_CURSOR_HELPER Path to lib/ai-quotas-cursor.js.
#   AI_QUOTAS_CURSOR_LOGIN_TIMEOUT_MS
#                           How long the headed cursor login waits for the
#                           dashboard to answer (helper default: 5 minutes).
#   Every override from AI_QUOTAS_CLAUDE_BIN down exists so the test suite can
#   exercise each path against stubs — no real login, keychain, browser, or
#   account. They are not meant for normal use.
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
#   2   `schedule` on a host that is not macOS. launchd is the only scheduler
#       that can reach this user's Keychain, CODEX_HOME directories, and
#       browser profiles, so there is nothing to install elsewhere — and a
#       cron line that ran the reader without them would record `needs-login`
#       every day and call it history.
#   3   Usage error: bad action, provider, or label; already-registered pair;
#       an ambiguous label that matches more than one provider.
#   4   No account matches the given label (remove / relogin / nick).
#   5   Dependency or write failure: `jq` missing, config unreadable,
#       unparseable, or written by a different schema major (never rewritten),
#       profile directory or config write failed.
#   6   The provider's login CLI could not be found — for `cursor`, node or
#       the Playwright helper. The exact command to run by hand is printed.
#   7   Contention, refused rather than raced; nothing is changed. Either the
#       config write lock was unavailable (timeout) or broken mid-update, or a
#       `relogin` found another relogin already running for the same account.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   - bash 3.2+, jq
#   - state-lock.sh (sibling library) for the config read-modify-write lock
#   - the provider's own CLI, only for `add` / `relogin`; for `cursor` that
#     is Node 20+ plus the Playwright pinned in .claude/scripts/lib

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

# --- the daily unattended snapshot (#1700) -----------------------------------
# One reverse-DNS label, fixed, because it is also the launchctl service name
# a user types by hand and the key `schedule remove` boots out.
LAUNCH_LABEL="com.claude.ai-quotas"
LAUNCH_AGENT_FILE="${AI_QUOTAS_LAUNCH_AGENT:-${_HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist}"
LAUNCHCTL_BIN="${AI_QUOTAS_LAUNCHCTL_BIN:-launchctl}"
LAUNCHD_LOG="${AI_QUOTAS_LAUNCHD_LOG:-${_HOME}/.claude/ai-quotas/launchd.log}"
HISTORY_FILE="${AI_QUOTAS_HISTORY:-${_HOME}/.claude/ai-quotas-history.jsonl}"
# 09:00 local. Late enough that the Mac is normally awake — launchd runs a
# missed calendar job at the next wake rather than skipping it, but a reading
# taken hours late is a reading attributed to the wrong day — and early enough
# that a day's usage has not yet accumulated, so consecutive snapshots measure
# a day apart rather than a day plus however long the owner slept in.
SCHEDULE_HOUR_DEFAULT="9"

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
ARG_NICK=""
NICK_GIVEN=0
ARG_HOUR=""
SCHEDULE_OP=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json)    JSON=1; shift ;;
    --no-login) NO_LOGIN=1; shift ;;
    # NICK_GIVEN, not `-n "$ARG_NICK"`: `--nick ""` is the documented way to
    # clear a nickname, and a flag whose "was it passed" test is the emptiness
    # of its value cannot tell clearing apart from not asking.
    --nick)
      [[ $# -ge 2 ]] || die_usage "--nick requires a name (pass '' to clear one)"
      ARG_NICK="$2"; NICK_GIVEN=1; shift 2 ;;
    --nick=*) ARG_NICK="${1#--nick=}"; NICK_GIVEN=1; shift ;;
    --hour)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--hour requires an hour (0-23)"
      ARG_HOUR="$2"; shift 2 ;;
    --hour=*) ARG_HOUR="${1#--hour=}"
      [[ -n "$ARG_HOUR" ]] || die_usage "--hour requires an hour (0-23)"
      shift ;;
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
  nick)
    # The name is POSITIONAL here — `nick <label> <name>` reads the way the
    # user says it — while `add` takes the same value through `--nick`,
    # because `add <provider> <label> <name>` would be three bare words in a
    # row and the first mis-ordering would register an account under a
    # nickname.
    # Refused rather than resolved: with both `nick <label> <name>` and
    # `--nick <other>` on one line, the positional below would silently
    # overwrite the flag, and the account would end up named the one the user
    # did not read last.
    [[ $NICK_GIVEN -eq 0 ]] \
      || die_usage "nick takes the name as its second argument — do not also pass --nick"
    [[ ${#POSITIONAL[@]} -ge 3 && ${#POSITIONAL[@]} -le 4 ]] \
      || die_usage "nick requires <label> <name> [<provider>] (pass '' as the name to clear one)"
    ARG_LABEL="${POSITIONAL[1]}"
    ARG_NICK="${POSITIONAL[2]}"
    NICK_GIVEN=1
    if [[ ${#POSITIONAL[@]} -eq 4 ]]; then
      ARG_PROVIDER="${POSITIONAL[3]}"
    fi
    ;;
  schedule)
    [[ ${#POSITIONAL[@]} -eq 2 ]] \
      || die_usage "schedule requires one of: install, remove, status"
    SCHEDULE_OP="${POSITIONAL[1]}"
    case "$SCHEDULE_OP" in
      install|remove|status) ;;
      *) die_usage "unknown schedule operation: $SCHEDULE_OP (expected install, remove, status)" ;;
    esac
    ;;
  *)
    die_usage "unknown action: $ACTION (expected list, add, nick, remove, relogin, schedule)"
    ;;
esac

if [[ $JSON -eq 1 && "$ACTION" != "list" ]]; then
  die_usage "--json applies to list only"
fi
if [[ $NO_LOGIN -eq 1 && "$ACTION" != "add" ]]; then
  die_usage "--no-login applies to add only"
fi
if [[ $NICK_GIVEN -eq 1 && "$ACTION" != "add" && "$ACTION" != "nick" ]]; then
  die_usage "--nick applies to add only (use 'nick <label> <name>' on an existing account)"
fi
# One check, not two: SCHEDULE_OP is set only by the `schedule` action, so
# `!= install` already covers every other action as well.
if [[ -n "$ARG_HOUR" && "$SCHEDULE_OP" != "install" ]]; then
  die_usage "--hour applies to 'schedule install' only"
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

# A nickname is DISPLAY text, so it is allowed the space in `GPT LM` that a
# label — which becomes a directory name — is not. What it may not contain is
# anything that would corrupt the surface it is displayed on: a tab or newline
# splits the reader's TSV row into columns that no longer line up with their
# headers, and a control character can rewrite the terminal around it. The
# 32-character cap is the table's, not an arbitrary one: the ACCOUNT column is
# the widest thing on a five-account row and a nickname longer than the email
# it replaces defeats the point.
valid_nickname() { # <nickname>
  # LC_ALL=C for the duration: bash matches bracket RANGES by the current
  # LC_COLLATE order, and in some locales `[$'\001'-$'\037']` does not cover
  # the C0 characters it names — the guard would then pass a control character
  # straight into the table it exists to protect. `local` on LC_ALL both
  # re-initialises the locale here and restores it on return.
  local LC_ALL=C
  [[ ${#1} -le 32 ]] || return 1
  # Printable ASCII and above, excluding the C0 range and DEL. `$'…'` ranges
  # keep this readable under LC_ALL variation, where a bracket expression
  # like [[:print:]] can accept a control character in some locales.
  case "$1" in
    *[$'\t\n\r']*) return 1 ;;
    *[$'\001'-$'\037']*) return 1 ;;
    *$'\177'*) return 1 ;;
  esac
  # Leading or trailing whitespace is refused rather than trimmed: a name that
  # renders identically to another one is a name the owner cannot tell apart
  # in `list`.
  [[ "$1" != " "* && "$1" != *" " ]] || return 1
  return 0
}

if [[ -n "$ARG_PROVIDER" ]]; then
  valid_provider "$ARG_PROVIDER" \
    || die_usage "unknown provider: $ARG_PROVIDER (expected claude, codex, or cursor)"
fi
if [[ $NICK_GIVEN -eq 1 && -n "$ARG_NICK" ]]; then
  valid_nickname "$ARG_NICK" \
    || die_usage "invalid nickname (max 32 characters, no tabs, newlines, control characters, or leading/trailing spaces)"
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
  # What to look for on PATH. It is the provider name for every provider that
  # ships its own CLI — and deliberately NOT for cursor: `command -v cursor`
  # finds the EDITOR launcher on any machine with Cursor installed, and
  # handing that to the login step would open an IDE instead of the browser
  # profile, then report the login as having run.
  local lookup="$provider"
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
    cursor)
      # Cursor has no login CLI. Its "login binary" is node, which runs the
      # Playwright helper that opens a real browser window for the user.
      override="${AI_QUOTAS_NODE_BIN:-}"
      lookup="node"
      candidates=(
        "/opt/homebrew/bin/node"
        "/usr/local/bin/node"
      )
      ;;
    *) return 1 ;;
  esac
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || return 1
    printf '%s' "$override"
    return 0
  fi
  if candidate="$(command -v "$lookup" 2>/dev/null)" && [[ -n "$candidate" ]]; then
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

# Where the Playwright helper lives. A missing helper is reported, never
# worked around: a "login" that silently did nothing would leave the account
# reading `needs-login` forever with no explanation on screen.
cursor_helper_path() {
  printf '%s' "${AI_QUOTAS_CURSOR_HELPER:-$SELF_DIR/lib/ai-quotas-cursor.js}"
}

manual_login_command() { # <provider> <profile_dir>
  case "$1" in
    claude) printf 'CLAUDE_CONFIG_DIR=%q claude %s' "$2" "${AI_QUOTAS_CLAUDE_LOGIN_ARGS:-}" ;;
    codex)  printf 'CODEX_HOME=%q codex login' "$2" ;;
    cursor) printf 'node %q --profile-dir %q --mode login' "$(cursor_helper_path)" "$2" ;;
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
    cursor)
      # A visible browser on this account's own persistent profile. The user
      # logs in to cursor.com the normal way; the helper waits until the
      # dashboard's usage endpoint answers, which is the only proof the
      # session actually landed, then closes and prints its verdict.
      #
      # The verdict is INSPECTED, not inferred from the exit status: the
      # helper exits 0 for every outcome it models, including
      # `needs-login`, so treating a clean exit as a successful login would
      # record an account whose session never arrived.
      local helper cursor_out
      helper="$(cursor_helper_path)"
      if [[ ! -r "$helper" ]]; then
        echo "${SELF_NAME}: the cursor login helper is missing at ${helper}." >&2
        echo "${SELF_NAME}: reinstall it from the repo, then re-run this login." >&2
        exit 6
      fi
      echo "${SELF_NAME}: a browser window will open on this account's profile — log in to cursor.com there."
      cursor_out="$("$bin" "$helper" --profile-dir "$dir" --mode login \
                     ${AI_QUOTAS_CURSOR_LOGIN_TIMEOUT_MS:+--timeout-ms "$AI_QUOTAS_CURSOR_LOGIN_TIMEOUT_MS"} \
                     2>/dev/null)" || true
      if printf '%s' "$cursor_out" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        return 0
      fi
      local why
      why="$(printf '%s' "$cursor_out" | jq -r '.detail // ""' 2>/dev/null || true)"
      echo "${SELF_NAME}: the cursor login did not complete${why:+ (${why})}." >&2
      return 1
      ;;
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
      # Chromium keeps its cookie store in one of three places depending on
      # the build, so all three are checked rather than betting the status on
      # one of them.
      # PRESENCE ONLY — the file is never opened, so no session value passes
      # through this tool.
      #
      # And presence is deliberately a weaker claim than the other providers
      # make: a cookie store exists as soon as a browser has run on this
      # profile, logged in or not. It is enough for the two things `list`
      # must get right — a completed login reads `ok`, and deleting the
      # cookies reads `needs-login` — and the note says plainly that only
      # `/quotas` proves the session still works. Running the headless read
      # here instead would put a 30-second browser start behind every `list`.
      local cookie_db
      for cookie_db in \
        "$dir/Default/Network/Cookies" \
        "$dir/Default/Cookies" \
        "$dir/Cookies"; do
        if [[ -s "$cookie_db" ]]; then
          CRED_DETAIL="browser profile present; /quotas confirms the session is live"
          return 0
        fi
      done
      CRED_DETAIL="no browser session in profile"
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

  if [[ $NO_LOGIN -eq 1 ]]; then
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
    --arg nickname "$ARG_NICK" \
    '{provider: $provider, label: $label, profile_dir: $profile_dir, added_at: $added_at}
     + (if $nickname == "" then {} else {nickname: $nickname} end)
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

  if [[ -n "$ARG_NICK" ]]; then
    echo "${SELF_NAME}: registered ${provider} account '${label}' as \"${ARG_NICK}\" (profile: ${dir})."
  else
    echo "${SELF_NAME}: registered ${provider} account '${label}' (profile: ${dir})."
  fi
}

# Set or clear an existing account's short display name. Registry-only: it
# touches no profile directory, runs no login, and reads no credential.
action_nick() {
  local config index provider label

  config="$(read_config)"
  index="$(resolve_single_index "$config" "$ARG_LABEL" "$ARG_PROVIDER")"
  provider="$(printf '%s' "$config" | jq -r --argjson i "$index" '.accounts[$i].provider')"

  state_lock_acquire "$CONFIG_FILE" || die 7 "timed out waiting for the config write lock"
  config="$(read_config)"
  # Re-resolved under the lock for the same reason `remove` re-resolves: the
  # index read a moment ago may name a different row now, and writing by a
  # stale index renames the wrong account.
  index="$(match_indices "$config" "$ARG_LABEL" "${ARG_PROVIDER:-$provider}" | head -n 1)"
  if [[ -z "$index" ]]; then
    state_lock_release || true
    die 4 "no account registered with label '$ARG_LABEL' (removed by another process?)"
  fi
  # Both label AND provider re-read from the LOCKED config, so the confirmation
  # describes the row that was actually written rather than the one the
  # pre-lock lookup saw.
  label="$(printf '%s' "$config" | jq -r --argjson i "$index" '.accounts[$i].label')"
  provider="$(printf '%s' "$config" | jq -r --argjson i "$index" '.accounts[$i].provider')"
  # An empty name DELETES the key rather than storing `""`. A reader asking
  # `.nickname // .label` would answer correctly either way, but one asking
  # `has("nickname")` would not, and the config should not carry a field whose
  # only meaning is "there isn't one".
  config="$(printf '%s' "$config" | jq --argjson i "$index" --arg nickname "$ARG_NICK" '
    .accounts[$i] = (if $nickname == ""
                     then (.accounts[$i] | del(.nickname))
                     else (.accounts[$i] + {nickname: $nickname}) end)')" \
    || { state_lock_release || true; die 5 "could not update the account entry"; }
  write_config "$config"
  state_lock_release || true

  if [[ -n "$ARG_NICK" ]]; then
    echo "${SELF_NAME}: ${provider} account '${label}' is now shown as \"${ARG_NICK}\"."
  else
    echo "${SELF_NAME}: ${provider} account '${label}' no longer has a nickname; /quotas will show its label."
  fi
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

# Undo the retirement performed by action_relogin when the login that followed
# it did not succeed. Without this, "'<label>' is unchanged" is false in the
# way that matters most: the registry row is untouched, but the account now
# points at a fresh EMPTY profile, so the very next `/quotas` reports
# `needs-login` for a session that was working a minute ago. A failed relogin
# must cost the user nothing.
#
# Returns 0 when the previous session is back at <dir>, 1 otherwise. Callers
# word their message from that answer rather than assuming either outcome.
restore_retired_profile() { # <dir> <retired>
  local dir="$1" retired="$2" failed
  [[ -d "$retired" ]] || return 1
  # <dir> ABSENT means someone else took it — this run created it a moment ago
  # (ensure_profile_dir) and has not touched it since, so the only way it is
  # gone is a concurrent relogin retiring it in turn. Restoring here would drop
  # a stale session into a path another login is actively writing, which is
  # worse than leaving this one retired. Refuse; the caller's message then
  # names the retirement instead of claiming a restore that did not happen.
  [[ -e "$dir" ]] || return 1
  # rmdir refuses a non-empty directory, which is exactly the test wanted: an
  # aborted login usually leaves nothing, and where it DID leave partial state
  # that state is moved aside rather than deleted — the same refusal to destroy
  # a profile that made the retirement a move in the first place.
  if ! rmdir "$dir" 2>/dev/null; then
    failed="${dir}.failed-login-$(date -u +%Y%m%d-%H%M%S)"
    [[ ! -e "$failed" ]] || failed="${failed}-$$"
    [[ ! -e "$failed" ]] || return 1
    mv "$dir" "$failed" 2>/dev/null || return 1
  fi
  # `mv olddir existingdir` moves INSIDE the target, so this runs only once
  # <dir> is gone — the clearing above is a precondition, not a tidy-up.
  [[ ! -e "$dir" ]] || return 1
  mv "$retired" "$dir" 2>/dev/null || return 1
  return 0
}

# Set while a retirement is OUTSTANDING — between the profile being moved aside
# and the relogin either succeeding or giving up. Cleared on success.
RELOGIN_PENDING_DIR=""
RELOGIN_PENDING_RETIRED=""

# Set while THIS process owns the relogin slot for a profile directory.
RELOGIN_SLOT_MARKER=""

# Refuse a second concurrent relogin for the same profile rather than letting
# both run (CodeAnt, PR #1689). The exposure is specific to the replace path:
# once the first relogin has moved the profile aside and recreated it, the
# second sees an ordinary-looking directory at <dir> and retires THAT — the
# fresh profile the first one's browser is actively writing into. Both then
# believe they own <dir>, and whichever finishes last writes the registry row,
# so the account ends up naming a profile holding someone else's half-written
# session. No status probe can describe that state, which is the same reason
# the replace exists at all.
#
# DETECT AND REFUSE, not a lock held across the login — the same call this
# script already makes for the overlapping-keychain case above. A login is an
# unbounded interactive flow (magic link, SSO), so any lock covering it outlives
# every staleness ceiling we have and gets broken mid-login anyway, which is
# worse than no lock: it looks serialized and is not.
#
# `mkdir` is the whole mechanism — it is atomic and it FAILS when the path
# exists, so exactly one caller can win. The holder's PID is recorded so a
# relogin killed hard (a lost terminal, a reboot mid-login) leaves a marker that
# the next run can prove dead and take over, instead of a permanent refusal the
# user has no documented way out of.
#
# The slot lives in a FLAT directory under the profile root, not as a sibling of
# the profile itself (CodeRabbit, local review). A sibling has to be created
# through the label and provider components of the profile path, and those are
# exactly the components `ensure_profile_dir` refuses to `mkdir -p` through
# until it has proved on the physical path that no symlink redirects them out of
# the root. Claiming here would have to either repeat that proof or run before
# it. Keying on the label instead puts the marker one component below the root
# that `ensure_profile_dir` itself creates unconditionally — and it means a
# relogin whose profile tree was deleted claims its slot and goes on to recreate
# the profile, rather than reporting contention it never raced for.
# The pid write FAILS THE CLAIM rather than being tolerated (CodeRabbit, local
# review). A marker whose pid cannot be read is treated as a live holder by the
# check above — deliberately, since guessing "probably dead" is what the whole
# guard exists to avoid — so silently keeping a marker this run could not stamp
# would convert a transient write error into a permanent, unexplained refusal of
# every future relogin for the account. Removing it and failing loudly leaves
# the account exactly as it was.
write_slot_pid() { # <marker> — 0 when the pid is on disk and readable
  local marker="$1"
  printf '%s\n' "$$" > "${marker}/pid" 2>/dev/null || return 1
  [[ "$(cat "${marker}/pid" 2>/dev/null || true)" == "$$" ]] || return 1
  return 0
}

claim_relogin_slot() { # <label> <provider> — sets RELOGIN_SLOT_MARKER
  local key slots marker recover holder=""
  # One flat component: the label is already restricted from climbing out of
  # the root, and this narrows it further rather than trusting that alone.
  key="$(printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._@+-' '_')"
  slots="$PROFILE_ROOT/.relogin-slots"
  mkdir -p "$slots" || die 5 "could not create the relogin slot directory: $slots"
  # Owner-only, like the profile root and every profile under it (CodeRabbit,
  # local review). These hold pids rather than credentials, but the mode is set
  # here rather than left to the ambient umask so the whole tree answers the
  # same way regardless of the shell the relogin was started from.
  chmod 700 "$slots" 2>/dev/null || true
  marker="$slots/$key"
  if ! mkdir "$marker" 2>/dev/null; then
    [[ -d "$marker" ]] || die 5 "could not claim the relogin slot at ${marker}; '${ARG_LABEL}' is unchanged"
    holder="$(cat "${marker}/pid" 2>/dev/null || true)"
    # Alive, or unreadable — either way this is not ours to take. An unreadable
    # PID is treated as alive on purpose: guessing "probably dead" is how two
    # logins end up sharing a profile, which is the outcome being prevented.
    if [[ ! "$holder" =~ ^[0-9]+$ ]] || kill -0 "$holder" 2>/dev/null; then
      die 7 "another relogin for '${ARG_LABEL}' is already running${holder:+ (pid ${holder})}; '${ARG_LABEL}' is unchanged — wait for it to finish, or remove ${marker} if you are sure it is not."
    fi
    # The holder is gone, so this run may take the slot over — but the takeover
    # is itself a read-modify-write on a shared path, and racing it unguarded
    # reintroduces the bug in a subtler form (CodeAnt/CodeRabbit, PR #1689): two
    # recoveries both find the marker dead, the first replaces it and starts a
    # login, and the second then moves that LIVE marker aside and claims the
    # slot on top of it. So the recovery takes its own atomic claim first.
    recover="${marker}.recovering"
    if ! mkdir "$recover" 2>/dev/null; then
      # Refused, never broken. This guard covers a handful of non-blocking
      # filesystem calls and nothing else — no login, no network, no lock wait —
      # so there is no legitimate "it is just slow" case to wait out, and
      # breaking it would only re-open the race it exists to close. A guard left
      # by a process killed inside those few syscalls is cleared by hand, which
      # the message says.
      die 7 "another relogin for '${ARG_LABEL}' is recovering this slot right now; '${ARG_LABEL}' is unchanged — re-run it in a moment, or remove ${recover} if no other relogin is running."
    fi
    # Re-read UNDER the guard. The pid read above is only a fast path: between
    # it and here, the dead holder's slot may have been taken over by a relogin
    # that is now very much alive, and taking it from that one is the exact
    # outcome being prevented.
    holder="$(cat "${marker}/pid" 2>/dev/null || true)"
    if [[ ! "$holder" =~ ^[0-9]+$ ]] || kill -0 "$holder" 2>/dev/null; then
      rmdir "$recover" 2>/dev/null || true
      die 7 "another relogin for '${ARG_LABEL}' claimed this slot while this one was recovering an abandoned marker; '${ARG_LABEL}' is unchanged — re-run it on its own."
    fi
    # Replaced rather than reused, so the marker this run goes on to own is one
    # it created, not one it inherited and cannot vouch for.
    rm -rf "${marker}.stale.$$" 2>/dev/null || true
    if ! mv "$marker" "${marker}.stale.$$" 2>/dev/null; then
      rmdir "$recover" 2>/dev/null || true
      die 5 "could not retire the abandoned relogin marker at ${marker}; '${ARG_LABEL}' is unchanged"
    fi
    rm -rf "${marker}.stale.$$" 2>/dev/null || true
    if ! mkdir "$marker" 2>/dev/null; then
      rmdir "$recover" 2>/dev/null || true
      die 5 "could not claim the relogin slot at ${marker} after retiring the abandoned one; '${ARG_LABEL}' is unchanged"
    fi
    if ! write_slot_pid "$marker"; then
      rm -rf "$marker" 2>/dev/null || true
      rmdir "$recover" 2>/dev/null || true
      die 5 "could not record this run's pid in the relogin slot at ${marker}; '${ARG_LABEL}' is unchanged"
    fi
    # Released only once the new marker carries this run's pid: a competing
    # recovery that acquires the guard next must see a LIVE holder, not the
    # empty marker it would otherwise feel entitled to take.
    rmdir "$recover" 2>/dev/null || true
    RELOGIN_SLOT_MARKER="$marker"
    return 0
  fi
  if ! write_slot_pid "$marker"; then
    rm -rf "$marker" 2>/dev/null || true
    die 5 "could not record this run's pid in the relogin slot at ${marker}; '${ARG_LABEL}' is unchanged"
  fi
  RELOGIN_SLOT_MARKER="$marker"
}

release_relogin_slot() {
  [[ -n "$RELOGIN_SLOT_MARKER" ]] || return 0
  local marker="$RELOGIN_SLOT_MARKER"
  RELOGIN_SLOT_MARKER=""
  rm -f "${marker}/pid" 2>/dev/null || true
  # `rmdir` first, then force. A marker that somehow holds more than the pid
  # file would survive the rmdir, and a surviving marker with no readable pid is
  # read as a LIVE holder by the next claim — so tolerating the failure here
  # would lock the account out of every future relogin (CodeRabbit, local
  # review). The path is this run's own slot marker under the profile root,
  # never a profile: releasing it can destroy nothing a login depends on.
  rmdir "$marker" 2>/dev/null || rm -rf "$marker" 2>/dev/null || true
}

# Rollback runs from an EXIT trap rather than from each failure branch, because
# the branches are not the whole exposure: `ensure_profile_dir` runs AFTER the
# move and exits through `die` from inside itself, with no return value the
# caller could test. Hanging the rollback off the two login failures would
# leave that one path uncovered — and a rollback that covers all but one exit
# is precisely the one a user eventually meets. The trap covers every exit in
# the window, expected or not.
#
# The message is derived from what the restore ACHIEVED, never from what it
# attempted: telling someone their session was put back when it was not is
# worse than saying nothing.
relogin_rollback_trap() {
  local code=$? dir retired
  if [[ -n "$RELOGIN_PENDING_RETIRED" ]]; then
    dir="$RELOGIN_PENDING_DIR"
    retired="$RELOGIN_PENDING_RETIRED"
    # Cleared FIRST, so a failure inside the restore cannot re-enter this trap.
    RELOGIN_PENDING_DIR=""
    RELOGIN_PENDING_RETIRED=""
    if restore_retired_profile "$dir" "$retired"; then
      echo "${SELF_NAME}: the relogin did not finish, so the previous session was put back at ${dir} — the account still works." >&2
    else
      echo "${SELF_NAME}: the relogin did not finish and the previous session could NOT be put back automatically; it is at ${retired} — move that directory back to ${dir} to recover it." >&2
    fi
  fi
  # Released LAST, and unconditionally: the slot has to outlive the rollback,
  # or a waiting relogin could claim the profile while this one is still
  # putting the previous session back into it.
  release_relogin_slot
  return "$code"
}

action_relogin() {
  local config index entry dir provider service="" before="" after=""
  config="$(read_config)"
  index="$(resolve_single_index "$config" "$ARG_LABEL" "$ARG_PROVIDER")"
  entry="$(printf '%s' "$config" | jq --argjson i "$index" '.accounts[$i]')"
  dir="$(printf '%s' "$entry" | jq -r '.profile_dir')"
  provider="$(printf '%s' "$entry" | jq -r '.provider')"
  service="$(printf '%s' "$entry" | jq -r '.credential_ref.service // ""')"

  # Claimed BEFORE the replace test below, not inside it. A cursor relogin whose
  # profile directory is missing takes the ordinary login path, and two of those
  # racing land two sessions in one freshly created profile just as surely — the
  # `-d "$dir"` branch is where the damage is loudest, not where it starts. The
  # trap is armed in the same step as the claim so no exit can leak the slot.
  claim_relogin_slot "$ARG_LABEL" "$provider"
  trap relogin_rollback_trap EXIT

  # A Cursor relogin REPLACES the profile rather than logging in on top of it
  # (issue #1668). Layering a second login over a half-expired session is how
  # a profile ends up holding two partial sessions and answering with
  # whichever one the browser picks — a state no status probe can describe.
  # The move is to a timestamped sibling, not a delete: an unrecoverable wipe
  # of a working login is exactly what `remove` refuses to do, and the same
  # reasoning applies here. The path is printed so it can be deleted by hand.
  if [[ "$provider" == "cursor" && -d "$dir" ]]; then
    # Dependencies FIRST. Moving the profile aside and only then discovering
    # that node or the helper is missing costs the user the session that was
    # still working — an unrecoverable-feeling failure caused entirely by the
    # order of two checks. `run_login` performs the same two checks a moment
    # later; doing them here is what makes this branch safe to enter.
    if ! provider_bin cursor >/dev/null 2>&1 || [[ ! -r "$(cursor_helper_path)" ]]; then
      echo "${SELF_NAME}: node or the cursor login helper is missing, so this relogin cannot run." >&2
      echo "${SELF_NAME}: '${ARG_LABEL}' is unchanged and its existing profile was left in place." >&2
      echo "  $(manual_login_command cursor "$dir")" >&2
      exit 6
    fi
    # Declared and assigned separately: `local x="$(cmd)"` makes the assignment
    # always succeed, masking a failing `date` behind a name that then reads
    # `.retired-` with nothing after it — every relogin colliding on one path.
    local retired
    retired="${dir}.retired-$(date -u +%Y%m%d-%H%M%S)"
    if [[ "$retired" == "${dir}.retired-" ]]; then
      die 5 "could not read the clock to name the retired cursor profile; '${ARG_LABEL}' is unchanged"
    fi
    # The stamp is whole-SECOND, so two relogins in the same second would
    # collide — and `mv olddir existingdir` does not fail there, it moves the
    # profile INSIDE the earlier retirement. The second one would vanish from
    # where its message says it went. Disambiguate rather than overwrite.
    if [[ -e "$retired" ]]; then
      local suffix=2
      while [[ -e "${retired}-${suffix}" && "$suffix" -lt 100 ]]; do
        suffix=$(( suffix + 1 ))
      done
      retired="${retired}-${suffix}"
      if [[ -e "$retired" ]]; then
        die 5 "could not find a free path to retire the cursor profile at ${dir}; '${ARG_LABEL}' is unchanged"
      fi
    fi
    if mv "$dir" "$retired" 2>/dev/null; then
      # Armed in the SAME step as the move: any exit from here on rolls the
      # retirement back (see relogin_rollback_trap).
      RELOGIN_PENDING_DIR="$dir"
      RELOGIN_PENDING_RETIRED="$retired"
      trap relogin_rollback_trap EXIT
      echo "${SELF_NAME}: previous cursor profile moved aside to ${retired} (delete it when you no longer want it)."
    else
      die 5 "could not move the existing cursor profile aside at ${dir}; '${ARG_LABEL}' is unchanged"
    fi
  fi

  ensure_profile_dir "$dir"
  if [[ "$provider" == "claude" ]]; then
    before="$(keychain_claude_services)"
  fi
  if ! run_login "$provider" "$dir"; then
    die 1 "the ${provider} login did not complete; the registry row for '${ARG_LABEL}' was not touched."
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
    die 1 "the ${provider} login finished but left no credential this script can see (${CRED_DETAIL}); the registry row for '${ARG_LABEL}' was not touched."
  fi
  # The login produced a credential, so the new profile is the one to keep:
  # disarm the rollback before anything downstream can exit through the trap
  # and undo a session that actually landed.
  RELOGIN_PENDING_DIR=""
  RELOGIN_PENDING_RETIRED=""
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

# --- the daily unattended snapshot (#1700) -----------------------------------
#
# WHY launchd AND NOT cron, AND NOT A CLAUDE SCHEDULER. The reader needs this
# user's login context — the Keychain items the `claude` login created, the
# per-account CODEX_HOME directories, the Cursor browser profile. A per-user
# LaunchAgent runs inside exactly that context. A cron line or an agent-side
# scheduler would run the same reader with none of it and record `needs-login`
# every day, which is not a gap in the history: it is a history full of
# confident wrong answers.
#
# The job is a RECORDER. It reads figures and appends them. Nothing in this
# repo consults them to decide whether work may proceed — quota and spend
# authority stays with Anthropic's own in-app UI and upstream harness signals
# (.claude/rules/safety.md §"Anthropic Quota & Spend Authority").

require_macos() { # <operation>
  [[ "$PLATFORM" == "Darwin" ]] && return 0
  echo "${SELF_NAME}: schedule $1 needs macOS launchd (this host reports '${PLATFORM}') — no daily snapshot job is installed here." >&2
  exit 2
}

# Every path this section touches derives from HOME — the LaunchAgent, the job
# log, the history file — and HOME may legitimately be unset here, because the
# top of the script accepts that as long as AI_QUOTAS_CONFIG and
# AI_QUOTAS_PROFILE_ROOT are both given. With it unset the agent resolves to
# `/Library/LaunchAgents/com.claude.ai-quotas.plist`, a MACHINE-WIDE location,
# and the log and history to `/.claude/…`. A per-user job aimed at a system
# path is not a degraded outcome to warn about; it is one to refuse. The plist
# also has to carry a real HOME for the reader to resolve anything at all.
require_schedule_home() { # <operation>
  [[ -n "$_HOME" ]] && return 0
  die 5 "HOME is unset, and every schedule path — the LaunchAgent, its log, the history file — derives from it; refusing to aim a per-user job at a system path. Set HOME and re-run 'schedule $1'."
}

# The path that goes INTO the plist. It has to outlive this checkout: a plist
# pointing into a worktree keeps working until the worktree is removed and then
# fails every night, logging to a file nobody reads. So the durable
# ~/.claude/ locations are preferred over the sibling copy, and choosing the
# sibling is said out loud rather than assumed to be fine.
resolve_reader_bin() {
  local candidate
  if [[ -n "${AI_QUOTAS_READER_BIN:-}" ]]; then
    # Used EXCLUSIVELY when set — no fall-through to the search. A seam that
    # falls back finds the repo copy through the sibling candidate whenever
    # the caller stands in a checkout, which is the only place the suite runs,
    # so the "reader unresolvable" path could never be exercised.
    if [[ -x "$AI_QUOTAS_READER_BIN" ]]; then
      printf '%s' "$AI_QUOTAS_READER_BIN"
      return 0
    fi
    die 5 "AI_QUOTAS_READER_BIN names '${AI_QUOTAS_READER_BIN}', which is not executable — refusing to schedule a job that cannot run"
  fi
  for candidate in \
    "${_HOME}/.claude/skills-worktree/.claude/scripts/ai-quotas.sh" \
    "${_HOME}/.claude/scripts/ai-quotas.sh"; do
    if [[ -x "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  if [[ -x "$SELF_DIR/ai-quotas.sh" ]]; then
    echo "${SELF_NAME}: scheduling the reader at $SELF_DIR/ai-quotas.sh — the durable copies under ~/.claude/ are not there yet, and a job pointing into a checkout stops working the day that checkout is removed. Re-run 'schedule install' once the skills worktree is in place." >&2
    printf '%s' "$SELF_DIR/ai-quotas.sh"
    return 0
  fi
  die 5 "ai-quotas.sh not found (checked ~/.claude/skills-worktree/.claude/scripts, ~/.claude/scripts, and $SELF_DIR) — nothing to schedule"
}

# `&` first: escaping it after `<` would re-escape the ampersand this function
# just introduced and turn `<` into `&amp;lt;`.
xml_escape() { # <text>
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Digits only, then compared in base 10 EXPLICITLY. `--hour 09` is a perfectly
# reasonable thing to type, and bash arithmetic reads a leading zero as octal —
# where `09` is not a valid digit at all, so the comparison fails with bash
# error text instead of accepting nine in the morning.
valid_hour() { # <hour>
  case "$1" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [[ ${#1} -le 2 ]] || return 1
  local h
  h=$(( 10#$1 ))
  [[ "$h" -ge 0 && "$h" -le 23 ]]
}

launch_uid() { id -u 2>/dev/null || true; }

# 0 when launchd holds the job. `list` is asked first because it answers with
# an exit status and nothing else; `print` is the modern spelling and is tried
# second so a future launchctl that drops `list` still reports correctly.
agent_is_loaded() {
  local uid
  "$LAUNCHCTL_BIN" list "$LAUNCH_LABEL" >/dev/null 2>&1 && return 0
  uid="$(launch_uid)"
  [[ -n "$uid" ]] || return 1
  "$LAUNCHCTL_BIN" print "gui/${uid}/${LAUNCH_LABEL}" >/dev/null 2>&1
}

# bootout, then the legacy unload. Neither failing is fatal on its own: the
# job may simply not be loaded, which is the state the caller wanted anyway.
# Returns 0 when the job is gone afterwards.
agent_unload() {
  local uid
  uid="$(launch_uid)"
  if [[ -n "$uid" ]]; then
    "$LAUNCHCTL_BIN" bootout "gui/${uid}/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  fi
  agent_is_loaded || return 0
  "$LAUNCHCTL_BIN" unload -w "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 || true
  # `agent_is_loaded && return 1` would be the same thing to read and a
  # different thing to run: under `set -e` an `A && B` whose A fails makes the
  # COMPOUND fail, which exits the script. It never fired here only because
  # both call sites happen to invoke this function inside a tested context,
  # where errexit is suspended — a property of the callers, not of this code.
  if agent_is_loaded; then
    return 1
  fi
  return 0
}

action_schedule_install() {
  local reader uid hour plist_dir tmp extra_env="" rc=0
  require_macos install
  require_schedule_home install

  hour="${ARG_HOUR:-${AI_QUOTAS_SCHEDULE_HOUR:-$SCHEDULE_HOUR_DEFAULT}}"
  valid_hour "$hour" || die_usage "invalid hour: ${hour} (expected 0-23)"
  # Normalised before it reaches the plist: `<integer>09</integer>` is not what
  # a property list means by an integer.
  hour=$(( 10#$hour ))

  # `die` inside a command substitution exits the SUBSHELL, so the abort on an
  # unresolvable reader rests entirely on `set -e` being in force at this call
  # site. Checked explicitly as well: a `set +e` introduced anywhere above would
  # otherwise turn "no reader found" into an empty path written confidently into
  # a plist, and a LaunchAgent with an empty program fails every night into a
  # log nobody reads.
  reader="$(resolve_reader_bin)" || exit $?
  [[ -n "$reader" ]] || die 5 "could not resolve which ai-quotas.sh to schedule"

  plist_dir="$(dirname "$LAUNCH_AGENT_FILE")"
  mkdir -p "$plist_dir" || die 5 "could not create $plist_dir"
  mkdir -p "$(dirname "$LAUNCHD_LOG")" || die 5 "could not create the log directory for $LAUNCHD_LOG"

  # PATH is spelled out because launchd gives a job a minimal one — typically
  # /usr/bin:/bin:/usr/sbin:/sbin — and every tool this reader needs beyond
  # the base system lives in Homebrew's prefix: `codex`, `node`, and `jq` are
  # all under /opt/homebrew/bin on this Mac (/usr/local/bin on Intel). Without
  # it the scheduled run finds no `jq`, exits 5, and writes a history file
  # with a hole in it every single night.
  #
  # HOME is passed for the same reason: the reader resolves the registry, the
  # profiles, and the history file from it, and a LaunchAgent's environment
  # does not necessarily carry the one this shell has.
  #
  # An AI_QUOTAS_CONFIG or AI_QUOTAS_HISTORY set in THIS shell is carried in
  # with them. Both override a HOME-derived default, so without this the
  # commands the user runs by hand — `schedule install`, `schedule status`,
  # and the reader itself — would honour a custom registry or history path
  # while the nightly job silently resolved the defaults instead: two history
  # files, each looking complete, neither holding every reading.
  #
  # AI_QUOTAS_PROFILE_ROOT is deliberately NOT carried. The reader never reads
  # it — every account's `profile_dir` comes from the registry, already
  # absolute — so passing it would advertise an effect it does not have.
  if [[ -n "${AI_QUOTAS_CONFIG:-}" ]]; then
    extra_env="${extra_env}
        <key>AI_QUOTAS_CONFIG</key>
        <string>$(xml_escape "$AI_QUOTAS_CONFIG")</string>"
  fi
  if [[ -n "${AI_QUOTAS_HISTORY:-}" ]]; then
    extra_env="${extra_env}
        <key>AI_QUOTAS_HISTORY</key>
        <string>$(xml_escape "$AI_QUOTAS_HISTORY")</string>"
  fi
  tmp="$(mktemp "${plist_dir}/.ai-quotas-plist.XXXXXX")" || die 5 "could not create a temp file in $plist_dir"
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$reader")</string>
        <string>--json</string>
        <string>--quiet</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$LAUNCHD_LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$LAUNCHD_LOG")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$(xml_escape "$_HOME")</string>${extra_env}
    </dict>
</dict>
</plist>
PLIST
  # The heredoc write is CHECKED, not assumed. A failed or truncated write —
  # a full disk is the ordinary cause — would otherwise be installed as a
  # plist, and launchd rejects a malformed one silently at load time.
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die 5 "could not write the plist to $tmp"; }
  # Validated BEFORE it is installed, where plutil exists. launchd rejects a
  # malformed plist silently at load time, so an escaping failure — a path
  # carrying a character this writer did not anticipate — would otherwise
  # present as a job that is installed, reports no error, and never runs.
  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      die 5 "the generated plist is not valid property-list XML — refusing to install a job launchd would silently reject (paths involved: ${reader}, ${LAUNCHD_LOG})"
    fi
  fi
  chmod 644 "$tmp" || { rm -f "$tmp"; die 5 "could not chmod the plist"; }
  mv "$tmp" "$LAUNCH_AGENT_FILE" || { rm -f "$tmp"; die 5 "could not install $LAUNCH_AGENT_FILE"; }

  # An already-loaded job is booted out first: bootstrap refuses a label
  # launchd already holds, so a re-install without this would leave the OLD
  # definition running while the new plist sat on disk looking installed.
  agent_unload || true
  uid="$(launch_uid)"
  if [[ -n "$uid" ]]; then
    "$LAUNCHCTL_BIN" bootstrap "gui/${uid}" "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 || rc=$?
  else
    rc=1
  fi
  # `bootstrap` is the modern spelling; `load -w` is what an older launchctl
  # understands. The fallback's status IS captured, and only because of what
  # the pair of failures means: launchd holds a job under a label, not a path,
  # so when neither spelling took AND the label still reports loaded, the
  # definition running tonight is the one that was loaded BEFORE this install
  # — the old hour, the old reader — even though the new plist is on disk and
  # `agent_is_loaded` answers yes. Reporting that as "is loaded" would be the
  # check that looks like one and is not.
  if [[ "$rc" -ne 0 ]]; then
    "$LAUNCHCTL_BIN" load -w "$LAUNCH_AGENT_FILE" >/dev/null 2>&1 && rc=0
  fi

  echo "${SELF_NAME}: wrote ${LAUNCH_AGENT_FILE}"
  echo "${SELF_NAME}: it runs ${reader} --json --quiet at ${hour}:00 local and once on load; output goes to ${LAUNCHD_LOG}"
  if agent_is_loaded && [[ "$rc" -eq 0 ]]; then
    echo "${SELF_NAME}: ${LAUNCH_LABEL} is loaded."
  elif agent_is_loaded; then
    # Loaded, but not by this install. NOT a die for the same reason as below
    # — the plist on disk is correct and takes effect at the next login — but
    # the user has to be told the job running until then is the previous one.
    echo "${SELF_NAME}: ${LAUNCH_LABEL} reports loaded, but neither bootstrap nor load took, so the definition launchd is running is the one loaded before this install — the new plist takes effect at your next login, or run: ${LAUNCHCTL_BIN} bootout gui/\$(id -u)/${LAUNCH_LABEL} && ${LAUNCHCTL_BIN} bootstrap gui/\$(id -u) ${LAUNCH_AGENT_FILE}" >&2
  else
    # NOT a die: the plist is installed and correct, and it will load at the
    # next login even if this bootstrap did not take. Saying so beats
    # reporting a failure the user cannot act on.
    echo "${SELF_NAME}: the plist is installed but launchctl did not report the job as loaded — it will load at your next login, or run: ${LAUNCHCTL_BIN} bootstrap gui/\$(id -u) ${LAUNCH_AGENT_FILE}" >&2
  fi
  echo "${SELF_NAME}: the job records usage readings; it never gates, pauses, or re-routes work."
}

action_schedule_remove() {
  local unloaded=0
  require_macos remove
  require_schedule_home remove

  agent_unload && unloaded=1
  if [[ -e "$LAUNCH_AGENT_FILE" ]]; then
    # A plain file, never a tree, and never through a wildcard — the path is
    # fixed by LAUNCH_LABEL or given explicitly.
    rm -f "$LAUNCH_AGENT_FILE" || die 5 "could not delete $LAUNCH_AGENT_FILE"
    echo "${SELF_NAME}: deleted ${LAUNCH_AGENT_FILE}"
  else
    echo "${SELF_NAME}: no plist at ${LAUNCH_AGENT_FILE} — nothing to delete."
  fi
  if [[ "$unloaded" -eq 1 ]]; then
    echo "${SELF_NAME}: ${LAUNCH_LABEL} is not loaded."
  else
    echo "${SELF_NAME}: launchctl still reports ${LAUNCH_LABEL} as loaded; run: ${LAUNCHCTL_BIN} bootout gui/\$(id -u)/${LAUNCH_LABEL}" >&2
  fi
  echo "${SELF_NAME}: the history already recorded at ${HISTORY_FILE} was left alone."
}

action_schedule_status() {
  local last=""
  require_macos status
  require_schedule_home status

  if [[ -e "$LAUNCH_AGENT_FILE" ]]; then
    echo "PLIST: ${LAUNCH_AGENT_FILE} (present)"
  else
    echo "PLIST: ${LAUNCH_AGENT_FILE} (absent — install with: ${SELF_NAME} schedule install)"
  fi
  if agent_is_loaded; then
    echo "JOB:   ${LAUNCH_LABEL} loaded"
  else
    echo "JOB:   ${LAUNCH_LABEL} not loaded"
  fi
  echo "LOG:   ${LAUNCHD_LOG}"

  # `fromjson?` drops a line it cannot parse rather than aborting, so one torn
  # line from a run killed mid-append does not cost the answer. The `type`
  # guard is the other half of that: `fromjson?` catches only the PARSE error,
  # so a line holding a bare `5` parses fine and then aborts jq on `.source`.
  #
  # `sort` before `tail`, for the reason the reader's own footer does it: rows
  # carry the clock their run STARTED on and land where it FINISHED, so a slow
  # run appending after a quick one leaves an older ts on the last line. This
  # sibling has to agree with `/quotas` about which reading is the latest —
  # two commands answering the same question differently is worse than either
  # answer being wrong. Fixed-width UTC, so the sort is exact.
  if [[ -r "$HISTORY_FILE" ]]; then
    last="$(jq -R -r 'fromjson?
                      | select(type == "object" and .source == "scheduled")
                      | .ts // empty' \
      "$HISTORY_FILE" 2>/dev/null | sort | tail -n 1 || true)"
  fi
  if [[ -n "$last" ]]; then
    echo "LAST SNAPSHOT: ${last} (scheduled)"
  else
    echo "LAST SNAPSHOT: none yet"
  fi
  echo
  echo "Display and configuration only — the job records readings and never gates dispatch."
}

action_schedule() {
  case "$SCHEDULE_OP" in
    install) action_schedule_install ;;
    remove)  action_schedule_remove ;;
    status)  action_schedule_status ;;
  esac
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

  local rows="" json_rows="[]" i provider label nickname dir service status detail
  for (( i = 0; i < count; i++ )); do
    provider="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].provider // ""')"
    label="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].label // ""')"
    # A non-string nickname is dropped rather than stringified, for the same
    # reason the reader drops it: a column showing a JSON fragment is worse
    # than one showing a dash.
    nickname="$(printf '%s' "$config" | jq -r --argjson i "$i" \
      '.accounts[$i].nickname // "" | if type == "string" then . else "" end')"
    dir="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].profile_dir // ""')"
    service="$(printf '%s' "$config" | jq -r --argjson i "$i" '.accounts[$i].credential_ref.service // ""')"
    # Called bare, never through `$(...)`: both results come back in globals.
    account_status "$provider" "$dir" "$service"
    status="$ACCOUNT_STATUS"
    detail="$CRED_DETAIL"
    if [[ $JSON -eq 1 ]]; then
      json_rows="$(printf '%s' "$json_rows" | jq \
        --arg provider "$provider" --arg label "$label" --arg profile_dir "$dir" \
        --arg status "$status" --arg detail "$detail" --arg nickname "$nickname" \
        '. += [{provider: $provider, label: $label,
                nickname: (if $nickname == "" then null else $nickname end),
                profile_dir: $profile_dir,
                status: $status, detail: $detail}]')"
    else
      rows+="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$provider" "$label" "${nickname:--}" "$status" "${detail:--}" "$dir")"$'\n'
    fi
  done

  if [[ $JSON -eq 1 ]]; then
    printf '%s\n' "$json_rows"
    return 0
  fi

  {
    printf 'PROVIDER\tLABEL\tNICKNAME\tSTATUS\tNOTE\tPROFILE_DIR\n'
    printf '%s' "$rows"
  } | column -t -s $'\t' 2>/dev/null || {
    printf 'PROVIDER\tLABEL\tNICKNAME\tSTATUS\tNOTE\tPROFILE_DIR\n'
    printf '%s' "$rows"
  }
  echo
  echo "Display only — never a dispatch or spend gate (.claude/rules/safety.md §Anthropic Quota & Spend Authority)."
}

case "$ACTION" in
  list)     action_list ;;
  add)      action_add ;;
  nick)     action_nick ;;
  remove)   action_remove ;;
  relogin)  action_relogin ;;
  schedule) action_schedule ;;
esac
