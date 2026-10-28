#!/usr/bin/env bash
# quota-reserve.sh — Pause autonomous work on an AI account that is nearly out of weekly allowance.
# catalog: token-measurement — Refresh a per-account reserve marker from the providers' own reported weekly usage (`/quotas`' reader) and decide, for a Claude Code hook, whether a tool call is autonomous work to block once an account crosses the owner's threshold (95% default); fails open on unreadable or stale readings
#
# PURPOSE
#   The owner runs several paid AI coding accounts and wants headroom left to ask
#   questions before one runs dry (issue #1863). When an account's weekly usage,
#   as REPORTED BY THE PROVIDER, reaches the threshold, work running unattended
#   on that account stops. The owner's own interactive turns do not.
#
#   This is the third carve-out in .claude/rules/safety.md §Anthropic Quota &
#   Spend Authority. It gates on the provider's own reported percentage, never on
#   a locally estimated figure. `/quotas` itself stays display-only.
#
# USAGE
#   quota-reserve.sh --refresh [--force]
#   quota-reserve.sh --status [--json]
#   quota-reserve.sh --decide              (hook payload JSON on stdin)
#   quota-reserve.sh --classify-prompt     (UserPromptSubmit payload JSON on stdin)
#   quota-reserve.sh --help | -h
#
# ACTIONS
#   --refresh         Read every registered account through ai-quotas.sh --json,
#                     keep the weekly window of each Claude and Codex account,
#                     and write the marker. A fresh marker is left alone unless
#                     --force. A failed read keeps the previous marker untouched
#                     and does NOT advance its read time, so stale readings age
#                     out and fail open. Notifies once when an account crosses in
#                     either direction.
#   --status          Print the marker. Exit 0 whether or not one exists.
#   --decide          Print one line for the hook: `allow`, `allow <why>`, or
#                     `deny <message>`. Always exits 0; the hook turns `deny` into
#                     exit 2.
#   --classify-prompt Record whether the current turn was started by the owner
#                     (`interactive`) or by an automated event (`automated`).
#
# WHAT COUNTS
#   Weekly windows only (`7-day…`). The five-hour window is ignored. Cursor is
#   not gated: the IDE has no hook surface and its limit is a dollar cap that
#   review-daily-cap.sh watches. Codex accounts appear in the marker and the
#   notification, but nothing stops Codex sessions yet (issue #1863 follow-up).
#
# WHAT IS BLOCKED, in a session on an account at or above the threshold
#   Always: launches (Agent, Workflow, Monitor, CronCreate, ScheduleWakeup,
#   RemoteTrigger, starting another session, background Bash).
#   In a subagent or an automated turn: everything except reads and the harness's
#   own bookkeeping scripts, so a pipeline can still checkpoint and park.
#   Never: ordinary tool calls in the owner's own interactive turns (launches are still blocked there).
#
# FAILS OPEN. No marker, a stale marker, an unreadable account file, a session
# whose account is not in the marker, or an unknown reading all allow. Work is
# never stopped on a reading that is not both fresh and known.
#
# CONFIGURATION (environment wins over the account config's `## Quota reserve`)
#   QUOTA_RESERVE_THRESHOLD_PCT   threshold_pct = N   default 95
#   QUOTA_RESERVE_ENABLED         enabled = true|false  default true (0/false/no/off disable)
#   QUOTA_RESERVE_DIR             marker directory (default ~/.claude/quota-reserve)
#   QUOTA_RESERVE_REFRESH_SECONDS age that triggers a background refresh (600)
#   QUOTA_RESERVE_STALE_SECONDS   age past which the marker is ignored (1800)
#   QUOTA_RESERVE_AI_QUOTAS_SH    the reader (default: ai-quotas.sh beside this script)
#   QUOTA_RESERVE_NOTIFY_CMD      command given one message argument (default: osascript on macOS)
#   QUOTA_RESERVE_CLAUDE_JSON     the session's .claude.json (default ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json)
#   QUOTA_RESERVE_NOW             clock override, epoch seconds (tests)
#
# EXIT STATUS
#   0  Done (including a refresh skipped because the marker is fresh).
#   2  Usage error.
#   3  --refresh could not read the providers; the previous marker is unchanged.
#   5  A dependency is missing (jq).
#
# EXAMPLES
#   quota-reserve.sh --refresh --force && quota-reserve.sh --status
#   QUOTA_RESERVE_THRESHOLD_PCT=90 quota-reserve.sh --refresh --force

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^# catalog:/ { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}
usage_error() { echo "quota-reserve.sh: $1" >&2; echo "Run with --help for usage." >&2; exit 2; }
warn() { echo "quota-reserve.sh: $*" >&2; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || HERE=""
SELF="${HERE:+$HERE/}$(basename "$0")"
DIR="${QUOTA_RESERVE_DIR:-$HOME/.claude/quota-reserve}"
MARKER="$DIR/marker.json"
TURNS="$DIR/turns"
REFRESH_SECONDS="${QUOTA_RESERVE_REFRESH_SECONDS:-600}"
STALE_SECONDS="${QUOTA_RESERVE_STALE_SECONDS:-1800}"
[[ "$REFRESH_SECONDS" =~ ^[0-9]+$ ]] || REFRESH_SECONDS=600
[[ "$STALE_SECONDS" =~ ^[0-9]+$ ]] || STALE_SECONDS=1800

now_epoch() {
  if [[ "${QUOTA_RESERVE_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$QUOTA_RESERVE_NOW"; else date +%s; fi
}

resolve_helper() { # <name> — sibling first, then the published locations
  local name="$1" c
  for c in ${HERE:+"$HERE/$name"} \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

# cfg_get <key> <default> — `key = value` from the account config's `## Quota reserve`
# section, with HTML comments stripped. Anything unreadable yields the default.
cfg_get() {
  local key="$1" default="$2" cfg helper section v
  cfg="${CLAUDE_ACCOUNT_CONFIG:-$HOME/.claude/account-config.md}"
  [[ -r "$cfg" ]] || { printf '%s' "$default"; return 0; }
  helper="$(resolve_helper pm-config-get.sh)" || { printf '%s' "$default"; return 0; }
  section="$("$helper" --file "$cfg" --section "Quota reserve" 2>/dev/null)" || { printf '%s' "$default"; return 0; }
  v="$(printf '%s\n' "$section" | awk -v k="$key" '
    { line = $0; out = ""
      while (1) {
        if (comment) { i = index(line, "-->"); if (i == 0) { line = ""; break } line = substr(line, i + 3); comment = 0 }
        else { i = index(line, "<!--"); if (i == 0) { out = out line; break } out = out substr(line, 1, i - 1); line = substr(line, i + 4); comment = 1 }
      }
      $0 = out }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); r = v }
    END { print r }')"
  if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$default"; fi
}

threshold_pct() {
  local v="${QUOTA_RESERVE_THRESHOLD_PCT:-}"
  [[ -n "$v" ]] || v="$(cfg_get threshold_pct 95)"
  if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 1 && "$v" -le 100 ]]; then printf '%s' "$v"; return 0; fi
  warn "threshold '$v' is not 1-100; using 95"
  printf '95'
}

enabled() {
  local v="${QUOTA_RESERVE_ENABLED:-}"
  [[ -n "$v" ]] || v="$(cfg_get enabled true)"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

need_jq() { command -v jq >/dev/null 2>&1 || { warn "jq not found"; exit 5; }; }

notify() { # <message> — best effort, never fatal
  local msg="$1" cmd="${QUOTA_RESERVE_NOTIFY_CMD:-}"
  msg="${msg//\"/}"; msg="${msg//\\/}"
  if [[ -n "$cmd" ]]; then
    "$cmd" "$msg" >/dev/null 2>&1 || true
  elif [[ "$(uname -s 2>/dev/null)" == Darwin ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"Quota reserve\"" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- --refresh ---
do_refresh() {
  local force="$1" now age reader rows thr lock tmp prev on
  need_jq
  mkdir -p "$DIR" 2>/dev/null || { warn "cannot create $DIR"; return 3; }
  now="$(now_epoch)"
  if [[ "$force" != 1 && -r "$MARKER" ]]; then
    age=$(( now - $(jq -r '.read_at // 0' "$MARKER" 2>/dev/null || echo 0) ))
    if [[ "$age" -ge 0 && "$age" -lt "$REFRESH_SECONDS" ]]; then return 0; fi
  fi

  # One refresh at a time. A lock older than five minutes is a crashed run.
  lock="$DIR/refresh.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if [[ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]]; then
      rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
    else
      return 0
    fi
  fi
  REFRESH_LOCK="$lock"
  trap 'rmdir "$REFRESH_LOCK" 2>/dev/null || true' RETURN

  reader="${QUOTA_RESERVE_AI_QUOTAS_SH:-}"
  if [[ -z "$reader" ]]; then reader="$(resolve_helper ai-quotas.sh)" || { warn "ai-quotas.sh not found"; return 3; }; fi
  [[ -f "$reader" && -x "$reader" ]] || { warn "the quota reader is not an executable file: $reader"; return 3; }
  # The reader appends to a history file on every run; point it somewhere inert so
  # a refresh every few minutes does not bury the daily record `/quotas` projects from.
  rows="$(AI_QUOTAS_HISTORY="$DIR/reader-history.jsonl" "$reader" --json 2>/dev/null)" \
    || { warn "the quota reader failed; keeping the previous marker"; return 3; }
  printf '%s' "$rows" | jq -e '.rows | type == "array"' >/dev/null 2>&1 \
    || { warn "the quota reader returned no rows; keeping the previous marker"; return 3; }

  thr="$(threshold_pct)"
  if enabled; then on=true; else on=false; fi
  tmp="$(mktemp "$DIR/marker.XXXXXX")" || { warn "cannot write a marker"; return 3; }
  printf '%s' "$rows" | jq --argjson thr "$thr" --argjson now "$now" --argjson on "$on" '
    def weekly: select((.window // "") | test("^7-day"));
    { schema_version: "1.0", read_at: $now, threshold_pct: $thr, enabled: $on,
      accounts: ([.rows[] | select(.provider == "claude" or .provider == "codex")]
        | group_by(.provider + "|" + .label)
        | map(. as $rs | $rs[0] as $f
            | [$rs[] | weekly | select(.status == "ok" and ((.used_pct | type) == "number"))] as $ok
            | { provider: $f.provider, label: $f.label, nickname: ($f.nickname // null),
                email: (($f.reported_email // $f.label) | ascii_downcase),
                used_pct: (if ($ok | length) > 0 then ($ok | map(.used_pct) | max) else null end),
                resets_at_epoch: (if ($ok | length) > 0 then ($ok | max_by(.used_pct) | .resets_at_epoch) else null end),
                state: (if ($ok | length) == 0 then "unknown"
                        elif ($ok | map(.used_pct) | max) >= $thr then "reserve" else "ok" end),
                note: (if ($ok | length) == 0 then ([$rs[] | weekly | .status] | first // "no weekly window") else null end) })) }' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; warn "could not build the marker"; return 3; }
  chmod 600 "$tmp" 2>/dev/null || true

  prev=""
  [[ -r "$MARKER" ]] && prev="$(cat "$MARKER" 2>/dev/null)"
  mv -f "$tmp" "$MARKER" || { rm -f "$tmp"; warn "could not install the marker"; return 3; }

  # Tell the owner once per crossing, in either direction.
  if [[ -n "$prev" ]] && printf '%s' "$prev" | jq -e . >/dev/null 2>&1; then
    jq -nr --argjson p "$prev" --slurpfile n "$MARKER" '
      ($p.accounts // []) as $pa | $n[0].accounts[]
      | . as $a | ($pa | map(select(.provider == $a.provider and .label == $a.label)) | first // null) as $was
      | select($was != null and $was.state != $a.state and ($a.state == "reserve" or $was.state == "reserve"))
      | (($a.nickname // $a.label) as $who
         | if $a.state == "reserve"
           then "\($who) is at \($a.used_pct)% of its weekly limit. Autonomous work on it is paused; your own turns still work."
           else "\($who) is back under the limit. Autonomous work can resume." end)' 2>/dev/null \
    | while IFS= read -r line; do [[ -n "$line" ]] && notify "$line"; done
  fi
  return 0
}

# ----------------------------------------------------------------- --status ---
do_status() {
  local json="$1" now age
  need_jq
  if [[ ! -r "$MARKER" ]]; then
    if [[ "$json" == 1 ]]; then echo '{"marker":null}'; else echo "No reserve marker yet. Run: quota-reserve.sh --refresh --force"; fi
    return 0
  fi
  now="$(now_epoch)"
  age=$(( now - $(jq -r '.read_at // 0' "$MARKER" 2>/dev/null || echo 0) ))
  if [[ "$json" == 1 ]]; then
    jq --argjson age "$age" --argjson stale "$STALE_SECONDS" '. + {age_seconds: $age, stale: ($age > $stale)}' "$MARKER"
    return 0
  fi
  jq -r --argjson age "$age" --argjson stale "$STALE_SECONDS" '
    "Threshold \(.threshold_pct)% of the weekly limit; reading \($age)s old\(if $age > $stale then " (STALE: ignored)" else "" end); gating \(if .enabled then "on" else "off" end)",
    (.accounts[] | "  \(.nickname // .label)  [\(.provider)]  \(if .used_pct == null then "unknown" else "\(.used_pct)%" end)  \(.state)\(if .note then "  (\(.note))" else "" end)")' "$MARKER"
}

# ------------------------------------------------------- --classify-prompt ---
# A turn is AUTOMATED when the harness or app started it, not the owner. Those
# arrive as wrapped events; everything else is the owner typing.
do_classify() {
  local input sid prompt kind
  need_jq
  input="$(cat 2>/dev/null || true)"
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null | head -c 400)"
  # Leading whitespace, blank lines included, must not hide a wrapper.
  prompt="${prompt#"${prompt%%[![:space:]]*}"}"
  kind=interactive
  case "$prompt" in
    "<ci-monitor-event>"*|"<task-notification>"*|"<side-sessions-event>"*|"[SYSTEM NOTIFICATION"*|\
    "<system-reminder>"*|"human-queue: D-"*|"[Artifact comment"*|"<scheduled-task"*|"<scheduled_task"*) kind=automated ;;
  esac
  mkdir -p "$TURNS" 2>/dev/null || return 0
  printf '%s\n' "$kind" > "$TURNS/$sid" 2>/dev/null || true
  # Housekeeping: drop turn records older than three days.
  find "$TURNS" -type f -mtime +3 -delete 2>/dev/null || true
  return 0
}

# ------------------------------------------------------------------ --decide ---
# Start a detached refresh, at most once per throttle window. Without this, a
# reader that keeps failing (a rate-limited provider, say) leaves the marker old,
# so EVERY tool call would start another attempt and hammer the very endpoint that
# is already refusing. The attempt is recorded before launching so a failure is
# throttled too.
spawn_refresh() {
  local throttle="${QUOTA_RESERVE_SPAWN_THROTTLE_SECONDS:-120}" last now f="$DIR/refresh-attempt"
  [[ "$throttle" =~ ^[0-9]+$ ]] || throttle=120
  now="$(now_epoch)"
  last="$(cat "$f" 2>/dev/null || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [[ "$last" -le "$now" && $(( now - last )) -lt "$throttle" ]]; then return 0; fi
  mkdir -p "$DIR" 2>/dev/null || return 0
  printf '%s\n' "$now" > "$f" 2>/dev/null || true
  ( nohup "$SELF" --refresh >/dev/null 2>&1 & ) >/dev/null 2>&1 || true
}

do_decide() {
  local input now read_at age email cj acct state tool bg cmd sid agent turn name pct reason autonomous
  need_jq
  enabled || { echo "allow disabled"; return 0; }
  input="$(cat 2>/dev/null || true)"
  if [[ -z "$input" ]] || ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then echo "allow unreadable hook payload"; return 0; fi

  now="$(now_epoch)"
  if [[ ! -r "$MARKER" ]]; then spawn_refresh; echo "allow no reading yet"; return 0; fi
  if ! jq -e '(.accounts | type) == "array" and ((.read_at | type) == "number")' "$MARKER" >/dev/null 2>&1; then
    spawn_refresh; echo "allow unreadable marker"; return 0
  fi
  read_at="$(jq -r '.read_at' "$MARKER" 2>/dev/null || echo 0)"
  [[ "$read_at" =~ ^[0-9]+$ ]] || { echo "allow unreadable marker"; return 0; }
  age=$(( now - read_at ))
  if [[ "$age" -ge "$REFRESH_SECONDS" ]]; then spawn_refresh; fi
  if [[ "$age" -gt "$STALE_SECONDS" ]]; then echo "allow stale reading"; return 0; fi

  # Which Claude account is THIS session on? The account email is metadata in the
  # session's own .claude.json; no credential is read.
  cj="${QUOTA_RESERVE_CLAUDE_JSON:-${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json}"
  email="$(jq -r '.oauthAccount.emailAddress // empty' "$cj" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [[ -n "$email" ]] || { echo "allow session account unknown"; return 0; }
  acct="$(jq -c --arg e "$email" '[.accounts[] | select(.provider == "claude" and .email == $e)] | first // empty' "$MARKER" 2>/dev/null)"
  [[ -n "$acct" ]] || { echo "allow account not in marker"; return 0; }
  state="$(printf '%s' "$acct" | jq -r '.state')"
  [[ "$state" == reserve ]] || { echo "allow $state"; return 0; }

  name="$(printf '%s' "$acct" | jq -r '.nickname // .label')"
  pct="$(printf '%s' "$acct" | jq -r '.used_pct')"
  tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
  bg="$(printf '%s' "$input" | jq -r '.tool_input.run_in_background // empty')"
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  agent="$(printf '%s' "$input" | jq -r '.agent_id // empty')"
  reason="${name} is at ${pct}% of its weekly limit. Autonomous work on it is paused so you keep headroom to ask questions. Your own messages still work. It resumes on its own after the reset; resume parked work with /go-on."

  # Launches are autonomous work by construction.
  case "$tool" in
    Agent|Workflow|Monitor|CronCreate|ScheduleWakeup|RemoteTrigger|mcp__ccd_session__start_session|mcp__ccd_session__hand_off_to_session)
      echo "deny $reason Launching $tool is blocked."; return 0 ;;
    Bash) [[ "$bg" == true ]] && { echo "deny $reason Background shell commands are blocked."; return 0; } ;;
  esac

  # Is this call autonomous? A subagent, or a turn the owner did not start.
  autonomous=0
  [[ -n "$agent" ]] && autonomous=1
  if [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ && -r "$TURNS/$sid" ]]; then
    turn="$(head -n 1 "$TURNS/$sid" 2>/dev/null)"
    [[ "$turn" == automated ]] && autonomous=1
  fi
  [[ "$autonomous" == 1 ]] || { echo "allow interactive turn"; return 0; }

  # Autonomous: reads and the harness's own bookkeeping may still run, so a
  # pipeline can checkpoint and park. Nothing else.
  case "$tool" in
    Read|Glob|Grep|TaskStop|TaskOutput|ToolSearch) echo "allow read-only while reserved"; return 0 ;;
    Bash)
      # A real invocation of one bookkeeping script: optionally `cd <dir> &&`, optionally
      # VAR=value prefixes, then the script, then plain arguments. No chaining, pipes,
      # redirects, or substitution anywhere, so a command that merely MENTIONS a script
      # name (`rm -rf x # session-state.sh`) or chains other work after it is not let through.
      local bk='^[[:space:]]*(cd[[:space:]]+[^;&|`$()<>[:space:]]+[[:space:]]*&&[[:space:]]*)?([A-Za-z_][A-Za-z0-9_]*=[^;&|`$()<>[:space:]]*[[:space:]]+)*([^;&|`$()<>[:space:]]*/)?(session-state|handoff-state|execution-pause|quota-reserve|bgwork-ceiling|issue-claim)\.sh([[:space:]][^;&|`$()<>]*)?[[:space:]]*$'
      # A newline or carriage return is a command separator that the regex's argument class would
      # otherwise accept, so a multi-line command is never a plain invocation.
      if [[ "$cmd" != *$'\n'* && "$cmd" != *$'\r'* && "$cmd" =~ $bk ]]; then
        echo "allow bookkeeping while reserved"; return 0
      fi ;;
  esac
  echo "deny $reason Park this work: write the handoff and stop (see .claude/reference/subagent-thread-limit-park.md)."
  return 0
}

# --------------------------------------------------------------------- main ---
ACTION=""; FORCE=0; JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --refresh|--status|--decide|--classify-prompt) [[ -z "$ACTION" ]] || usage_error "only one action at a time"; ACTION="$1"; shift ;;
    --force) FORCE=1; shift ;;
    --json) JSON=1; shift ;;
    -*) usage_error "unknown flag: $1" ;;
    *) usage_error "unexpected argument: $1" ;;
  esac
done
[[ -n "$ACTION" ]] || usage_error "choose an action"
[[ "$FORCE" == 0 || "$ACTION" == --refresh ]] || usage_error "--force only applies to --refresh"
[[ "$JSON" == 0 || "$ACTION" == --status ]] || usage_error "--json only applies to --status"

case "$ACTION" in
  --refresh) do_refresh "$FORCE"; exit $? ;;
  --status) do_status "$JSON"; exit $? ;;
  --decide) do_decide; exit 0 ;;
  --classify-prompt) do_classify; exit 0 ;;
esac
