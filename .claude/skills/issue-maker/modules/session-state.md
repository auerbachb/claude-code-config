# Session state and capture boundary

> Load only for: a new `/issue-maker` session or compaction/restart recovery
> Prerequisites: dispatcher classified the turn as capture-mode work

## Step 1: Establish (or recover) capture mode

The thread's capture state lives in a session log so it survives context compaction.

**The log must be private to this conversation.** `scripts/resolve-log.sh` owns that decision — never derive the path inline. It uses `$CLAUDE_SESSION_ID` when the harness exports one and otherwise mints a stable per-conversation fallback key, because `CLAUDE_SESSION_ID` resolves *empty* inside Bash tool subshells: the old `${CLAUDE_SESSION_ID:-default}` expression silently pointed every concurrent session at one shared file, and on 2026-08-26 two sessions interleaved writes on it (issue #1369).

Resolve both session helpers relative to the already-selected dispatcher so a bundled or installed skill uses the matching scripts even when invoked outside the repository working directory.

<!-- test-anchor: issue-maker-step1-resolve-log -->
```bash
mkdir -p "$HOME/.claude/handoffs"
: "${DISPATCHER:?resolve the issue-maker dispatcher before session setup}"
# The dispatcher is the authority for the skill root. Do not guess from cwd or
# derive a session-log path here; resolve-log.sh retains the private-key logic.
ISSUE_MAKER_ROOT=$(cd -- "$(dirname -- "$DISPATCHER")/.." && pwd -P) || {
  echo "FATAL: could not resolve the issue-maker skill root from DISPATCHER" >&2
  exit 1
}
RESOLVE_LOG=""
candidate="$ISSUE_MAKER_ROOT/scripts/resolve-log.sh"
[ -x "$candidate" ] && RESOLVE_LOG="$candidate"
[ -n "$RESOLVE_LOG" ] || { echo "FATAL: scripts/resolve-log.sh not found — is the issue-maker skill installed?" >&2; exit 1; }
LOG="$("$RESOLVE_LOG")" || { echo "FATAL: resolve-log.sh could not resolve a session log path" >&2; exit 1; }
SESSION_ID="$("$RESOLVE_LOG" --key --quiet)"
# BATCH_TIER tracks the most demanding tier seen so far in this session.
# Initialized here so it is always defined — both new-log and compaction-recovery
# paths start fresh at "Light" and accumulate upward during Step 3.
BATCH_TIER="Light"
OFFER_ACCEPTED=false
DELIVERY_MODE=inline
```

`resolve-log.sh` writes any note or warning to **stderr** — surface those to the user rather than swallowing them. A `WARN:` naming a `session_id` mismatch means another conversation is already writing to this path: stop and start a fresh capture thread instead of filing into it.

**Drift recovery (issue #1572).** The `claude` process that identifies a conversation can change underneath it — an overnight sleep/wake or a harness reconnect is enough — and the pre-#1572 resolver answered that by minting a *second* key, stranding the batch on a new empty log. `resolve-log.sh` now records a conversation-stable anchor in each marker, so a drifted invocation resolves back to the **original** log and says so (`NOTE: … kept its ORIGINAL key …`). When several markers claim one anchor with different keys it `WARN`s, names every candidate, picks the newest deterministically, and mints nothing — surface that warning and inspect the losing logs before any batch-wide write.

<!-- test-anchor: issue-maker-log-write-helper -->
```bash
# Bind the read/write selector before recovering the session list.
# set_log() and checkpoint() are initialized below before any mutation.

# Repo-scoped row selector for batch-wide writes. Defines a jq function `mine`
# that matches only this session's own open rows, plus the bare boolean
# `same_repo` it is built from — for a write that must stay per-repo without
# `mine`'s open-status constraint (Step 10). Concatenate it in front of a
# filter — `set_log "$MINE_DEF"'(.issues[] | mine | …)' --arg repo "$REPO"` —
# and always pass `--arg repo "$REPO"` alongside.
#
# Repo attribution matches `active-work-cap.sh` exactly, so the writer and the
# readers of this log agree on which rows belong to which repo. A row with no
# attributable url matches NOTHING here: the readers over-count an
# unattributable row (safe for a cap), while a writer must under-reach (safe
# for someone else's data).
MINE_DEF='def same_repo: (($repo | length) > 0 and (((.url // "") | (try capture("^https?://[^/]+/(?<r>[^/]+/[^/]+)/issues/") catch {r:""}) // {r:""} | .r | ascii_downcase) == ($repo | ascii_downcase))); def session_filed: (.origin == "create" or (.origin == null and .created_at != null and (.edited_at == null or .tier != null or .delivers != null or .est_bound != null or .chain != null))); def mine: select(.status == "open" and same_repo and session_filed); '
```

**If `$LOG` exists (compaction recovery / re-invocation):** read it and lead with a recap before accepting new input — this is the first action after a compaction.

```bash
if [ -f "$LOG" ]; then
  REPO=$(jq -r '.target_repo // empty' "$LOG") || { echo "FATAL: session log is unreadable — cannot recover target repository" >&2; exit 1; }
  if [ -z "$REPO" ]; then
    echo "FATAL: recovered session has no target repository — ask for owner/repo and persist it before operation work" >&2
    exit 1
  fi
  if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ; then
    echo "FATAL: session log contains an invalid target repository — refusing to continue" >&2
    exit 1
  fi
  jq -r 'if .checkpoint then "Resume checkpoint: \(.checkpoint.operation) / \(.checkpoint.module_phase) — issue \(.checkpoint.issue // "—") in \(.checkpoint.repository // .target_repo // "unknown repo"). Evidence: \(.checkpoint.current_evidence // "none persisted"). Next: \(.checkpoint.next_step // "reclassify request")." else empty end' "$LOG"
  # Restore the chain identity even when the active phase is dedup/file/postfile;
  # recovery must not need to re-run the new-chain drafting module.
  IS_INCREMENT=false; CHAIN_ID=""; CHAIN_JSON=null
  if jq -e '.active_chain != null' "$LOG" >/dev/null; then
    CHAIN_REPO=$(jq -er '.active_chain.repository' "$LOG") || exit 1
    [[ "$CHAIN_REPO" == "$REPO" ]] || { echo "FATAL: active chain belongs to another repository" >&2; exit 1; }
    CHAIN_ID=$(jq -er '.active_chain.chain_id' "$LOG") || exit 1
    TOTAL=$(jq -er '.active_chain.total' "$LOG") || exit 1
    POSITION=$(jq -r --arg id "$CHAIN_ID" --arg repo "$REPO" "$MINE_DEF"'
      ([.issues[] | select(same_repo and .chain.chain_id == $id) | .chain.position] | max // 0) + 1' "$LOG") || exit 1
    IS_INCREMENT=true
  fi
  OFFER_ACCEPTED=$(jq -r '.offer_accepted // false' "$LOG")
  DELIVERY_MODE=$(jq -r '.delivery_mode // "inline"' "$LOG")
  # Re-derive BATCH_TIER from tiers stored in prior issues so the batch offer
  # after compaction reflects the true running maximum, not a cold reset.
  BATCH_TIER=$(jq -r --arg repo "$REPO" "$MINE_DEF"'
    .issues | map(mine | .tier // "Light")
    | if contains(["Heavy"]) then "Heavy"
      elif contains(["Standard"]) then "Standard"
      else "Light"
      end' "$LOG")
  jq -r --argjson accepted "$OFFER_ACCEPTED" --arg dmode "$DELIVERY_MODE" --arg repo "$REPO" \
    "$MINE_DEF"'.handoff_checkpoint.spawn_status as $spawn_status | "Resuming \(if $accepted then "execution" else "capture" end) mode for \(.target_repo) — \(.mode) mode. \(([.issues[]|mine]|length)) issue(s) opened so far:",
     (if .handoff_checkpoint then "  Handoff recovery needed — \(.handoff_checkpoint.state); registry \(.reg_tid // "unavailable"); task \(.handoff_checkpoint.task_id // "unknown"); spawn \(.handoff_checkpoint.spawn_status // "unknown")" else empty end),
     (.issues[] | select(same_repo) | "  #\(.number) — \(.title) [\(.status)]" +
                  (if .chip_task_id and ($accepted | not) and ($dmode == "chip-pending") then (if $spawn_status == "spawned" then " — chip spawned; task receipt needs reconciliation" else " — spawn outcome unknown; reconcile before any retry" end)
                   elif .chip_task_id and ($accepted | not) and ($dmode == "chip-reserved") then " — capacity reserved; no spawn confirmed"
                   elif .chip_task_id and ($accepted | not) and ($dmode == "chip") then " — chip spawned; task ID recorded"
                   elif .chip_task_id and ($accepted | not) then " — offer pending"
                   elif .chip_task_id and $accepted then " — offer accepted, running"
                   else "" end))' "$LOG"
fi
```

Offer tokens are not launch receipts. `inline` means a printed/pending inline offer; `chip-reserved` means no spawn was attempted; `chip-pending` means a launch may have occurred; `chip` with a returned task ID confirms success. Legacy `chip-pending`/`reserved` receipts without the new `spawn_status` are **unknown**, never proof that a chip started. A persisted `spawned` or `spawned-receipt-pending` task ID is affirmative evidence; a failed second write may leave only `spawn-uncertain`. Do not claim unknown work happened or release its capacity.

For an outstanding receipt, the next active phase is `offer:handoff` reconciliation only. Read the checkpoint repository (must equal target repo), registry ID, saved task ID, and `spawn_status`. With `not-started` and state `reservation-intent`, `reserved`, or `cleanup-pending`, resolve the registry and read `--repo "$REPO" --list` for that exact ID before choosing cleanup; no automatic reserve/spawn replay. An absent/retracted/expired entry plus confirmed no-spawn permits local receipt cleanup; an offered entry permits repo-scoped release followed by local cleanup. Running/pr-backed entries override stale local not-started assumptions and require task reconciliation. Registry read failure/ambiguous identity preserves the receipt. With unknown spawn, use the tool's task inventory/returned result to establish whether a task exists; absence of a registry entry alone proves nothing about spawn. Confirmed running tasks keep their registry ID until their actual terminal lifecycle transition. A closed captured issue is not proof of task termination. Never erase a receipt to enable another offer.

If `OFFER_ACCEPTED` is false, re-affirm: *"Still in capture mode — describe issues to create, or use `/update #N …`, `edit #N …`, or `close #N`."* If `OFFER_ACCEPTED` is true, re-affirm: *"Offer accepted — execution mode active. New issues filed here will be run inline via `/subagent`."* If the log is corrupt/unreadable, warn the user and offer to start a fresh session log.

**If `$LOG` does not exist:** initialize it and print the mode banner.

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
# Mode is seeded from the invocation: `/issue-maker rapid-fire` (or the word
# "rapid-fire" in $ARGUMENTS) starts in rapid-fire; otherwise default.
MODE="default"; case "$ARGUMENTS" in *rapid-fire*) MODE="rapid-fire";; esac
NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
TMP=$(mktemp)
jq -n --arg repo "$REPO" --arg now "$NOW" --arg sid "$SESSION_ID" --arg mode "$MODE" \
  '{schema_version:"1", session_id:$sid, target_repo:$repo, mode:$mode,
    created_at:$now, last_updated_at:$now, issues:[]}' > "$TMP" && mv "$TMP" "$LOG"
```

Banner: *"Thread is now in issue-capture mode. I will only create, edit, or close issues — no implementation, no worktrees, no branches. Describe an issue and I'll open it, then report a quick summary and the scope calls I made."*

### Initialize the atomic log writer before any log mutation

Resolve this once after `$LOG` is selected and before the repo-retarget guard writes `.target_repo`:

```bash
SET_LOG=""
: "${DISPATCHER:?resolve the issue-maker dispatcher before log writes}"
ISSUE_MAKER_ROOT=$(cd -- "$(dirname -- "$DISPATCHER")/.." && pwd -P) || {
  echo "FATAL: could not resolve the issue-maker skill root from DISPATCHER" >&2
  exit 1
}
candidate="$ISSUE_MAKER_ROOT/scripts/set-log.sh"
[ -x "$candidate" ] && SET_LOG="$candidate"
[[ -n "$SET_LOG" ]] || { echo "FATAL: scripts/set-log.sh not found — is the issue-maker skill installed?" >&2; exit 1; }
set_log() { "$SET_LOG" "$LOG" "$@"; }

# Persist a compact phase receipt before and after each module.
checkpoint() {
  local operation="$1" phase="$2" issue="${3:-}" repo="$4" evidence="$5" next="$6"
  set_log '.checkpoint = {operation:$operation, module_phase:$phase,
    issue:(if $issue == "" then null else $issue end), repository:$repo,
    current_evidence:$evidence, next_step:$next}' \
    --arg operation "$operation" --arg phase "$phase" --arg issue "$issue" \
    --arg repo "$repo" --arg evidence "$evidence" --arg next "$next"
}
```

**Repo detection (AC):** the `gh repo view` above auto-detects the target repo from cwd. If it returns empty (not a git repo / `gh` failed / ambiguous), **ask the user** which `owner/repo` to target before creating anything, then **persist it to the log** so compaction recovery and later `--repo` calls see it:

<!-- test-anchor: issue-maker-step1-retarget-guard -->
```bash
REPO="<owner/repo the user supplied>"
# Persist only the slug format accepted by recovery. Do not store a URL, path,
# whitespace, or an incomplete owner/repository value in target_repo.
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "ERROR: expected owner/repo before retargeting; target_repo was not changed" >&2
  exit 1
fi
if jq -e '(.reg_tid // "") != "" or .handoff_checkpoint != null or .delivery_mode == "chip" or .delivery_mode == "chip-pending" or .delivery_mode == "chip-reserved"' "$LOG" >/dev/null; then
  echo "ERROR: reconcile the existing handoff in its saved repository before retargeting" >&2
  exit 1
fi
# Never flip target_repo out from under entries that belong to another repo —
# that is one of the three #1369 corruptions. Warn and hold instead.
# A row whose url cannot be attributed is not counted: it cannot be shown to be
# foreign. An UNREADABLE log is a refusal, not a zero — a guard that writes
# because its own check failed is no guard.
FOREIGN=$(jq -r --arg repo "$REPO" '
  [.issues[]
   | select(.status == "open")
   | ((.url // "") | (try capture("^https?://[^/]+/(?<r>[^/]+/[^/]+)/issues/") catch {r:""}) // {r:""} | .r | ascii_downcase) as $r
   | select(($r | length) > 0 and $r != ($repo | ascii_downcase))] | length' "$LOG") || FOREIGN=""
case "$FOREIGN" in
  0) set_log '.target_repo = $v' --arg v "$REPO" ;;  # see the write-log helper below
  ''|*[!0-9]*)
    echo "WARN: could not read $LOG to check for foreign entries — refusing to retarget to $REPO (issue #1369). Fix or replace the log first." >&2; exit 1 ;;
  *)
    echo "WARN: $LOG already holds $FOREIGN open issue(s) from another repo — refusing to retarget to $REPO (issue #1369). Start a fresh capture thread, or close/retract the foreign entries first." >&2; exit 1 ;;
esac
```

Every `gh issue …` call below passes `--repo "$REPO"`.

### Writing to the session log (one canonical helper)

Every mutation of `$LOG` goes through `scripts/set-log.sh` (skill-local) — an atomic read-modify-write helper. Resolve and bind it once per invocation, together with the repo-scoped row selector every batch-wide write must use:

**The repo/origin selector was initialized before recovery; use it for every session-wide read and write.**


**Origin and legacy rows.** New filings carry `origin:"create"`; update-only backfills carry `origin:"update"`. `mine` excludes update-only rows from offer stamping, cleanup, execution, and the session tally. Legacy rows without origin count as filed only with a creation timestamp and either no edit timestamp or positive create-time metadata (tier, delivered scope, estimate, or chain). An ambiguous legacy backfill remains excluded until GitHub/session evidence establishes that this conversation filed it; do not guess from repository and open status alone. Reads that build an offer list, recover its maximum tier, or calculate sharers must use the same selector, even when no write occurs. Per-issue update/retract uses `same_repo` and may still operate on update-only entries.

Examples used below: `set_log '.target_repo = $v' --arg v "$REPO"`, `set_log '.mode = $v' --arg v rapid-fire`, and the create/close updates in Steps 9 and 12.

**Never write a batch-wide filter that selects on `status` alone.** `(.issues[] | select(.status == "open") | …)` reaches every open row in the file. That was correct only while the log was assumed session-private; when two conversations shared one log on 2026-08-26 it overwrote a foreign session's `chip_task_id` (issue #1369). Per-issue writes scoped by `.number` (Steps 10 and 12) and top-level scalars (`.mode`, `.offer_accepted`, `.delivery_mode`, `.reg_tid`) are already narrow and need no change; every *batch* write goes through `mine`.

**`.number` alone is narrow, not unique.** Two repos sharing one log can both hold an issue `#42`, so Step 10 pairs `.number` with `same_repo` in **both** its existence check and its row selector, and Step 12's close does the same. Guarding only the write is not enough: an unscoped *existence* check enters the update branch on a foreign row, bumps that row, and never backfills this repo's — leaving the issue you just edited missing from the tally entirely. Scoping both predicates means a log holding only a foreign `#42` falls through to the backfill branch and this repo gets its own row. A row with no attributable url matches neither predicate, so it is left untouched — the same under-reach the writer rule above requires.

---

## Step 2: Refusal behavior — capture mode holds until acceptance

**If `OFFER_ACCEPTED` is false** and the user asks for workflow-advancing work — **"implement"**, **"code this"**, **"fix the code"**, **"create a worktree"**, **"create a branch"**, **"start working on"**, or invokes `/start-issue`, `/fixpr`, `/wrap` — **politely decline in one line and stay in capture mode**:

> "This thread is in capture mode — I only create, edit, and close issues here. Finish filing issues and I'll offer to run them inline, or start a fresh thread with `/start-issue #N`."

**Capture mode holds until the user accepts the end-of-session inline offer (Step 9c).** Since [#1229](https://github.com/auerbachb/claude-code-config/issues/1229) every other thread runs subagent-fit work inline rather than handing it to a new tab (`chip-launching.md` "PM-context inline gate"); this invariant is the exception, scoped to **until acceptance** — not for the thread's lifetime. An accepted offer ends capture mode: the thread becomes execution-capable and runs the filed batch through `/subagent`. Until that acceptance, the thread refuses implement/code/worktree/branch requests and never polls for a CR plan.

Never create worktrees/branches, never edit code, and **never poll for a CodeRabbit plan in this thread** while in capture mode. The repo's `.github/workflows/cr-plan-on-issue.yml` auto-comments `@coderabbitai plan` on the issue itself when it's opened (it skips bot-authored issues); the issue's CR plan lands on the *issue*, asynchronously, with no action needed here. Do **not** post `@coderabbitai plan` yourself and do **not** wait on it.

**If `OFFER_ACCEPTED` is true** (execution mode active), workflow-advancing requests are welcome — handle them through `/subagent`.

---
