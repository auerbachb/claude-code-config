#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# catalog: token-measurement — Deliver private, once-per-account/local-day logout notifications for scheduled quota reports; never log in or read credentials.
# Internal scheduled-report consumer. Input: report JSON path. All failures are
# fail-open. State is claimed before delivery: a failed delivery is not retried
# that day. No endpoint detail, reported email, token, or password is consumed.
set -uo pipefail
SELF_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
command -v jq >/dev/null 2>&1 || exit 0
[[ "$#" -eq 1 && -f "$1" && ! -L "$1" ]] || exit 0
state="${AI_QUOTAS_NOTIFY_STATE:-${HOME:-}/.claude/ai-quotas-notifications.json}"
[[ -n "${AI_QUOTAS_NOTIFY_STATE:-}" || -n "${HOME:-}" ]] || exit 0
day="${AI_QUOTAS_NOTIFY_DAY:-$(date +%F)}"
[[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || exit 0
[[ -r "$SELF_DIR/state-lock.sh" && -r "$SELF_DIR/lib/bounded-run.sh" ]] || exit 0
# shellcheck source=./state-lock.sh
source "$SELF_DIR/state-lock.sh" || exit 0
# shellcheck source=./lib/bounded-run.sh
source "$SELF_DIR/lib/bounded-run.sh" || exit 0
umask 077
parent="${state%/*}"; [[ "$parent" != "$state" ]] || parent=.
[[ -d "$parent" ]] || mkdir -p "$parent" || exit 0
# Refuse special files/symlinks before the shared lock can inspect metadata.
[[ ! -L "$state" && ( ! -e "$state" || -f "$state" ) ]] || exit 0
[[ ! -L "$state.lock" && ( ! -e "$state.lock" || -d "$state.lock" ) ]] || exit 0
[[ ! -L "$state.lock/owner" && ( ! -e "$state.lock/owner" || -f "$state.lock/owner" ) ]] || exit 0
work="$(mktemp -d "$parent/.quotas-notify.XXXXXX")" || exit 0
cleanup_notify() {
  state_lock_release 2>/dev/null || true
  # Only explicitly owned files and the private directory; no recursive cleanup.
  for name in prior candidates pending next out err; do
    [[ ! -f "$work/$name" ]] || unlink "$work/$name"
  done
  rmdir "$work" 2>/dev/null || true
}
trap 'cleanup_notify' EXIT
# Never adopt an inherited unrelated acquisition or let callers extend the wait.
unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN
state_lock_acquire "$state" 1 >/dev/null 2>&1 || exit 0
# Recheck after acquisition. Bound prior state and fail closed on corruption;
# resetting it would permit duplicate delivery attempts.
[[ ! -L "$state" && ( ! -e "$state" || -f "$state" ) ]] || exit 0
printf '[]' > "$work/prior"
if [[ -e "$state" ]]; then
  size="$(wc -c < "$state")" || exit 0
  [[ "$size" -le 1048576 ]] || exit 0
  jq -es 'length==1 and (.[0] | type=="array" and length<=1000 and all(type=="object" and
    (.provider=="claude" or .provider=="codex" or .provider=="cursor") and
    (.label|type=="string" and length>0 and length<=512) and (.day|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))))' "$state" >/dev/null 2>&1 || exit 0
  cp "$state" "$work/prior" || exit 0
fi
# Only allowlisted metadata reaches delivery. Control-bearing labels are refused
# rather than copied into native notifications or command arguments.
jq -ce '[.rows[] | select(.status=="needs-login") |
  select(.provider=="claude" or .provider=="codex" or .provider=="cursor") |
  select(.label|type=="string" and length>0 and length<=512 and (test("[\u0000-\u001f\u007f]")|not)) |
  {provider,label}] | unique | if length<=1000 then . else error("too many accounts") end' "$1" > "$work/candidates" 2>/dev/null || exit 0
jq -n --slurpfile prior "$work/prior" --slurpfile candidates "$work/candidates" --arg day "$day" '
  [$candidates[0][] | . as $a | select(any($prior[0][]; .provider==$a.provider and .label==$a.label and .day==$day)|not)]' > "$work/pending" || exit 0
jq -n --slurpfile prior "$work/prior" --slurpfile pending "$work/pending" --arg day "$day" '
  ([$prior[0][] | {provider,label,day}] + [$pending[0][] | . + {day:$day}]) |
  ([.[].day] | unique | sort | .[-7:]) as $days |
  if ($days|length)>0 and $day<$days[0] then error("date outside retained window")
  else map(select(.day >= $days[0])) end |
  if length<=1000 then . else error("too many accounts") end' > "$work/next" 2>/dev/null || exit 0
chmod 600 "$work/next" || exit 0
state_lock_commit "$work/next" "$state" >/dev/null 2>&1 || exit 0
state_lock_release >/dev/null 2>&1 || exit 0
export CAPTURE="$work/out" CAPTURE_ERR="$work/err"
while IFS= read -r account; do
  provider="$(printf '%s' "$account" | jq -r .provider)"
  label="$(printf '%s' "$account" | jq -r .label)"
  action="$(printf '%s' "$account" | jq -r 'if .provider=="cursor" then "open the Cursor IDE and sign in" else
    "/quotas-setup relogin " + (if (.label|startswith("-")) then "-- " else "" end) + (.label | if test("^[A-Za-z0-9@._+%-]+$") then . else @sh end) + " " + .provider end')"
  if [[ -n "${AI_QUOTAS_NOTIFY_BIN:-}" ]]; then
    run_bounded 3 "$AI_QUOTAS_NOTIFY_BIN" "$provider" "$label" "$action" >/dev/null 2>&1 || true
  elif [[ -x /usr/bin/osascript ]]; then
    # Static AppleScript, metadata in argv: never interpolate data into code.
    run_bounded 3 /usr/bin/osascript -e 'on run argv
      display notification (item 2 of argv) with title ("AI quotas: " & item 1 of argv)
    end run' "$provider: $label" "$action" >/dev/null 2>&1 || true
  fi
done < <(jq -c '.[]' "$work/pending")
trap - EXIT
cleanup_notify
exit 0
