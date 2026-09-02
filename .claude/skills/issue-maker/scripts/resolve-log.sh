#!/usr/bin/env bash
# resolve-log.sh — resolve THIS conversation's /issue-maker session log.
#
# Usage: resolve-log.sh [--key] [--quiet]
#
#   (no flags)  print the absolute log path on stdout
#   --key       print the session key alone (no path)
#   --quiet     suppress the stderr notes/warnings (stdout is unaffected)
#
# Notes and warnings always go to stderr, so stdout stays a single clean line a
# caller can capture directly.
#
# WHY THIS EXISTS (issue #1369)
#   SKILL.md used to derive the log name inline from
#   `${CLAUDE_SESSION_ID:-default}`. `CLAUDE_SESSION_ID` does not reach Bash
#   tool subshells, so EVERY concurrent conversation on the machine resolved
#   the same `~/.claude/handoffs/issue-maker-default-log.json` and interleaved
#   writes on it. On 2026-08-26 that produced three distinct corruptions inside
#   one six-minute window: `target_repo` flipped under a live session, a
#   foreign session's issue appearing inside another session's batch, and a
#   batch-wide offer stamp overwriting a foreign row's `chip_task_id`.
#
#   A silent shared `default` key must therefore never happen again.
#
# THE KEY
#   1. `$CLAUDE_SESSION_ID` when set — sanitized to [A-Za-z0-9._-].
#   2. Otherwise a derived `fallback-<digest>` key, minted ONCE per
#      conversation and persisted in a marker file, so every later invocation
#      in the same conversation (compaction recovery included) resolves the
#      SAME log.
#
# CONVERSATION IDENTITY — WHY NOT `$PPID` (measured, 2026-08-26)
#   The obvious fallback is `$PPID` plus cwd. It does not work: the depth of
#   the shell chain between this script and the harness VARIES per invocation.
#   Two Bash tool calls in one conversation measured
#
#       bash < bash < zsh < claude(53630) < …      (call 1)
#       bash < bash < zsh < claude(53630) < …      (call 2)
#
#   where every `bash`/`zsh` pid differed between the calls and only the
#   `claude` pid held still — and a command substitution adds another level
#   again. Keying on `$PPID` would therefore mint a NEW log on nearly every
#   invocation and strand the batch on the first compaction recovery.
#
#   So identity is the nearest ancestor process named `claude` — the CLI
#   process that owns this conversation — plus its start time. It is stable
#   across Bash tool calls and across shell-depth changes, and it differs
#   between concurrent conversations, which are separate `claude` processes.
#   The start time means a recycled pid mints a new key instead of adopting a
#   dead conversation's log.
#
#   `ISSUE_MAKER_CONV_ID` overrides the walk with an explicit identity string.
#   Nothing in the skill sets it; it exists so tests can simulate two distinct
#   conversations without building fake process trees.
#
#   The marker is looked up by the identity digest ALONE, deliberately not by
#   cwd: the Bash tool's cwd can drift between calls, and a key that moved with
#   it would strand a batch mid-session. cwd is folded into the minted digest
#   as extra entropy only — it separates two conversations that somehow share a
#   `claude` process (a subagent working in its own worktree) at mint time,
#   without making later lookups depend on it.
#
#   Markers are ~30 bytes each and are left in place; nothing here deletes
#   files.
#
# THE STABLE ANCHOR — WHY THE IDENTITY ALONE IS NOT ENOUGH (issue #1572)
#   The identity above is stable across Bash tool calls but NOT across the life
#   of a long conversation. Measured on 2026-09-01/02: one conversation minted
#   `fallback-2f10e6843c1623b89316` (marker `imk-88384cc93e6e778c0fd9`), then —
#   same conversation, after an overnight laptop sleep and a ~10h gap — walked
#   to a different `claude` ancestor and minted `fallback-5e6d548d4d51dae8487f`
#   against a log that did not exist. #1369 is two conversations sharing one
#   log; this is its mirror image, ONE conversation fragmenting across two, and
#   it silently loses the offer/chip bookkeeping `/wave` and `/pm` read.
#
#   So each marker also records a STABLE ANCHOR: a conversation identifier the
#   harness itself hands to the Bash tool subshell, which therefore survives the
#   `claude` process being restarted underneath the conversation.
#
#       1. `$ISSUE_MAKER_STABLE_ANCHOR`  — explicit override (tests).
#       2. `host=$CLAUDE_CODE_HOST_SESSION_ID` — the harness's per-conversation
#          host id; survives a CLI restart within one conversation.
#       3. `sid=$CLAUDE_CODE_SESSION_ID`  — the CLI session id.
#       4. nothing derivable -> EMPTY, which disables adoption entirely and
#          leaves the pre-#1572 behaviour exactly as it was.
#
#   When the identity came from `ISSUE_MAKER_CONV_ID`, the ambient harness ids
#   are deliberately IGNORED: a simulated conversation must not borrow the real
#   one's anchor, or every fabricated identity in a test would look like the
#   same conversation.
#
#   WHY NOT tty/sess (measured, 2026-09-02): under the desktop entrypoint every
#   process in the chain reports `tty=??` and `sess=0`, so a tty-derived anchor
#   would be IDENTICAL for every conversation on the machine — adoption keyed on
#   it would re-create #1369 wholesale. A harness-issued conversation id cannot
#   collapse two conversations that way.
#
# ADOPTION — PREFER THE EXISTING LOG, NEVER SILENTLY MINT A SIBLING
#   On an exact `imk-<IDENT_DIGEST>` miss with a non-empty anchor, the marker
#   directory is scanned for markers recording the SAME anchor:
#
#       0 candidates  -> mint a fresh key and publish (a genuinely new
#                        conversation; the #1369 path is untouched).
#       1 key         -> adopt it and emit a NOTE naming the drift.
#       2+ keys       -> WARN naming every candidate marker and its key, then
#                        adopt deterministically (newest recorded epoch; the
#                        lexicographically smallest key breaks a tie). Nothing
#                        is minted while candidates exist.
#
#   The adopted key is then published at `imk-<IDENT_DIGEST>` so the next call
#   under the drifted identity takes the fast path.
#
#   Adoption is deliberately NOT gated on the recorded `claude` pid still being
#   dead. A liveness gate would refuse the very case the ACs name — an ancestor
#   chain that changed while the process lives — and a check that cannot run on
#   a fabricated identity is a guard that passes by not running. The anchor
#   being a per-conversation harness id, not a machine-wide attribute, is what
#   keeps two live conversations apart.
#
# MARKER RECORD FORMAT
#   Line 1 is the `fallback-<hex>` key — unchanged, so any reader that took the
#   first line still works. Later lines are `name=value`:
#
#       fallback-2f10e6843c1623b89316
#       ident=claude=65325|start=Tue Sep 1 22:29:54 2026
#       anchor=host=local_216f4b64-082f-4a40-b9b0-657e99f70c7a
#       epoch=1756846194
#
#   A legacy single-line marker reads as key-only with an empty anchor, and is
#   rewritten in the new format on its next exact hit — that migration is what
#   lets an already-running conversation survive its FIRST drift.
#
# FILENAME SHAPE IS LOAD-BEARING
#   `issue-maker-<key>-log.json` under `~/.claude/handoffs/` is globbed by
#   `active-work-cap.sh`, `/wave`, and `/pm`. Those readers never inspect the
#   key segment, so a new key shape is transparent to them — but the
#   `issue-maker-*-log.json` shape itself must not change.
#
# Exit codes:
#   0  Resolved (path or key printed on stdout)
#   2  Usage error
#   4  No SHA-256 tool available — cannot mint a collision-resistant key

set -euo pipefail

MODE=path
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --key)   MODE=key ;;
    --path)  MODE=path ;;
    --quiet) QUIET=1 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *)
      echo "resolve-log.sh: unknown option: $1" >&2
      echo "Usage: resolve-log.sh [--key] [--quiet]" >&2
      exit 2 ;;
  esac
  shift
done

warn() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

HANDOFF_DIR="$HOME/.claude/handoffs"
MARKER_DIR="$HANDOFF_DIR/.issue-maker-keys"
mkdir -p "$HANDOFF_DIR"

# digest <material> — 20 hex chars. Returns 4 when no SHA-256 tool exists, so
# the caller aborts loudly rather than quietly falling back to a guessable key.
digest() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,20)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,20)}'
  else
    return 4
  fi
}

no_digest_tool() {
  echo "resolve-log.sh: could not compute a SHA-256 digest — shasum or sha256sum must be present and working" >&2
  echo "resolve-log.sh: refusing to fall back to a shared log name (issue #1369)" >&2
  exit 4
}

# conversation_identity — print "claude=<pid>|start=<lstart>" for the nearest
# ancestor process named `claude`, or nothing when there is no such ancestor.
# Walking (rather than reading $PPID) is what makes this survive the varying
# shell depth documented in the header.
conversation_identity() {
  local pid line ppid comm base start depth
  pid="${PPID:-0}"
  depth=0
  while [ "$depth" -lt 24 ]; do
    case "$pid" in ''|0|1) return 0 ;; esac
    line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || line=""
    [ -n "$line" ] || return 0
    ppid="$(printf '%s' "$line" | awk '{print $1}')"
    # `comm` is a full path on macOS and may contain spaces, so take every
    # field after the first. Only the basename is compared, and the compare is
    # case-sensitive: the desktop app higher in the chain is `Claude`, which is
    # shared across conversations and must never match.
    comm="$(printf '%s' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
    base="${comm##*/}"
    if [ "$base" = "claude" ]; then
      start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || true)"
      printf 'claude=%s|start=%s' "$pid" "$start"
      return 0
    fi
    pid="$ppid"
    depth=$((depth + 1))
  done
  return 0
}

# stable_anchor — print this conversation's anchor, or nothing when none can be
# derived. Reads $IDENT_SOURCE, so it must run after the identity is resolved.
stable_anchor() {
  if [ -n "${ISSUE_MAKER_STABLE_ANCHOR:-}" ]; then
    printf '%s' "$ISSUE_MAKER_STABLE_ANCHOR" | tr -d '\r\n'
    return 0
  fi
  # A simulated identity never borrows the ambient conversation's anchor.
  # (Written as an `if`, not `[ … ] && return`: under `set -e` a false test as
  # the last command of a function body would kill the script.)
  if [ "$IDENT_SOURCE" = "override" ]; then
    return 0
  fi
  if [ -n "${CLAUDE_CODE_HOST_SESSION_ID:-}" ]; then
    printf 'host=%s' "$(printf '%s' "$CLAUDE_CODE_HOST_SESSION_ID" | tr -d '\r\n')"
    return 0
  fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf 'sid=%s' "$(printf '%s' "$CLAUDE_CODE_SESSION_ID" | tr -d '\r\n')"
    return 0
  fi
  return 0
}

# marker_key <file> — the `fallback-<hex>` key on line 1, or nothing. An
# unreadable marker yields the empty string rather than a non-zero status: every
# caller already treats "no well-formed key" as absent, and under `set -e` a
# failing pipeline here would abort the resolve instead.
marker_key() { head -n 1 "$1" 2>/dev/null | tr -d '\r\n' || true; }

# marker_field <file> <name> — the value of the LAST `<name>=…` line, or
# nothing. One awk process, never a pipeline: under `set -o pipefail` a producer
# killed by a short-reading consumer would abort the whole script.
marker_field() {
  awk -v k="$2" '
    index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
    END { if (v != "") printf "%s", v }
  ' "$1" 2>/dev/null || true
}

# settled_marker_key <file> — the marker's key, re-read a bounded number of
# times while it is absent. An EXISTING marker can be legitimately keyless for a
# moment: the `noclobber` fallback in publish_marker below creates the file
# EMPTY and only then writes the record, so a racer reading inside that window
# sees nothing where a perfectly good key is about to appear. Treating that
# snapshot as malformed would overwrite the winner and leave the two callers on
# DIFFERENT keys — the split this file exists to prevent. Waiting the window out
# costs nothing on the common paths (a well-formed marker returns on the first
# read, and a marker that does not exist at all never sleeps) and the wait is
# bounded, so a genuinely corrupt marker still falls through to the re-mint.
settled_marker_key() {
  local k="" i=0
  while : ; do
    k="$(marker_key "$1")"
    case "$k" in fallback-[0-9a-f]*) break ;; esac
    [ -e "$1" ] || break
    [ "$i" -lt 5 ] || break
    i=$((i + 1))
    # A `sleep` that cannot do fractions must not abort the resolve; losing the
    # pause only degrades this to the previous read-once behaviour.
    sleep 0.05 2>/dev/null || true
  done
  printf '%s' "$k"
}

# marker_record <key> — the marker body for $key under the current identity.
marker_record() {
  printf '%s\n' "$1"
  printf 'ident=%s\n' "$(printf '%s' "$IDENT" | tr -d '\r\n')"
  printf 'anchor=%s\n' "$(printf '%s' "$STABLE_ANCHOR" | tr -d '\r\n')"
  printf 'epoch=%s\n' "$(date -u +%s)"
}

# staged_marker — write a COMPLETE record for $SESSION_KEY to a temp file in
# $MARKER_DIR and print its path, or print nothing on failure. Every marker now
# reaches its final name already complete, so a concurrent reader can never
# observe a half-written record (a reader that caught only line 1 would read the
# marker as anchor-less legacy and drift right past its own log).
staged_marker() {
  local tmp=""
  mkdir -p "$MARKER_DIR" 2>/dev/null || return 0
  tmp="$(mktemp "${MARKER_DIR}/.imk-stage.XXXXXX" 2>/dev/null)" || return 0
  if marker_record "$SESSION_KEY" > "$tmp" 2>/dev/null; then
    printf '%s' "$tmp"
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# write_marker — replace $MARKER with a complete record, atomically. Used where
# an overwrite is intended: the epoch/anchor refresh on an exact hit (also the
# MIGRATION path — a legacy one-line marker gains its anchor here, which is what
# lets an already-running conversation survive its first drift) and the
# malformed-marker re-mint below. Best effort throughout: a failed write must
# never cost the caller its already-resolved key.
write_marker() {
  local tmp=""
  tmp="$(staged_marker)"
  [ -n "$tmp" ] || return 0
  mv -f "$tmp" "$MARKER" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# publish_marker — create $MARKER holding $SESSION_KEY with an EXCLUSIVE create,
# never a plain overwrite. Two invocations of one conversation can both reach
# this — the parent and a subagent it spawned share the `claude` ancestor that IS
# the identity — and cwd is folded into the minted digest, so their keys
# genuinely differ. An overwriting publish would leave each racer on the key it
# minted and future calls on whichever landed last: one conversation split
# across two logs, which is #1369 in miniature. So the first writer wins and
# every loser adopts the winning key.
#
# The exclusive create is `ln` of a fully-written temp file: it fails when the
# target exists (the O_EXCL half) AND the winner's marker is complete from the
# instant it appears (which a `noclobber` redirect is not — it creates an EMPTY
# file, then writes, and a loser reading in that window would see no key and
# re-mint its own). `noclobber` remains the fallback for the case where no temp
# file could be staged at all.
publish_marker() {
  local won="" tmp=""
  mkdir -p "$MARKER_DIR"
  tmp="$(staged_marker)"
  if [ -n "$tmp" ]; then
    if ln "$tmp" "$MARKER" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  # `ln` failing almost always means the target already exists — a lost race,
  # handled below. But it also fails when nothing could be staged, or on a
  # filesystem with no hard links, and there the exclusive publish never ran at
  # all. So try the O_EXCL redirect before giving up on exclusivity: it fails on
  # an existing target too, landing in the same loser path.
  if ( set -o noclobber; marker_record "$SESSION_KEY" > "$MARKER" ) 2>/dev/null; then
    return 0
  fi
  if [ -r "$MARKER" ]; then
    # settled_marker_key, not marker_key: reaching here means the marker already
    # existed, and the noclobber branch above publishes it EMPTY-then-written.
    # Reading once could catch that window and send us down the re-mint arm,
    # destroying the winner's marker and keeping our own key.
    won="$(settled_marker_key "$MARKER")"
  fi
  case "$won" in
    fallback-[0-9a-f]*)
      # Lost the race. Adopt the winner so both callers converge on ONE log.
      SESSION_KEY="$won"
      ;;
    *)
      # The existing marker is unreadable or malformed, so it owns no batch
      # worth protecting. Replace it with our well-formed key — the same
      # re-mint the corrupt-marker check performs.
      write_marker
      ;;
  esac
  return 0
}

# adopt_from_anchor — on an exact-digest miss, find the markers that record this
# conversation's anchor and adopt the right key instead of minting a sibling.
# Sets SESSION_KEY / KEY_SOURCE / ADOPTED_FROM / CANDIDATE_LIST / CANDIDATE_KEYS
# when it finds one; leaves everything untouched when it does not.
adopt_from_anchor() {
  local files="" f="" k="" e="" first=""
  local best_key="" best_file="" best_epoch=-1
  [ -d "$MARKER_DIR" ] || return 0
  files="$(grep -l -F -x -e "anchor=${STABLE_ANCHOR}" -- "$MARKER_DIR"/imk-* 2>/dev/null || true)"
  [ -n "$files" ] || return 0

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    k="$(marker_key "$f")"
    # A marker with no well-formed key owns no batch and is not a candidate.
    case "$k" in fallback-[0-9a-f]*) : ;; *) continue ;; esac
    e="$(marker_field "$f" epoch)"
    case "$e" in ''|*[!0-9]*) e=0 ;; esac
    CANDIDATE_LIST="${CANDIDATE_LIST}${CANDIDATE_LIST:+, }${f} -> ${k}"
    case " ${CANDIDATE_KEYS} " in
      *" ${k} "*) : ;;
      *)
        CANDIDATE_KEYS="${CANDIDATE_KEYS}${CANDIDATE_KEYS:+ }${k}"
        CANDIDATE_KEY_COUNT=$((CANDIDATE_KEY_COUNT + 1))
        ;;
    esac
    if [ "$e" -gt "$best_epoch" ]; then
      best_epoch="$e"; best_key="$k"; best_file="$f"
    elif [ "$e" -eq "$best_epoch" ] && [ -n "$best_key" ] && [ "$k" != "$best_key" ]; then
      # Deterministic tie-break: the lexicographically smallest key wins, in the
      # C collation so the choice does not move with the caller's locale.
      # `sed -n 1p` rather than `head -n 1`: sed reads to EOF, so `sort` is never
      # killed mid-write, which under `set -o pipefail` would fail the whole
      # command substitution.
      first="$(printf '%s\n%s\n' "$k" "$best_key" | LC_ALL=C sort | sed -n '1p')"
      if [ "$first" = "$k" ]; then best_key="$k"; best_file="$f"; fi
    fi
    # The loop's own status is never meaningful — a trailing `if` that simply
    # did not match would otherwise fail the compound command under `set -e`.
  done <<< "$files" || true

  [ -n "$best_key" ] || return 0
  SESSION_KEY="$best_key"
  ADOPTED_FROM="$best_file"
  KEY_SOURCE="adopted"
  return 0
}

SESSION_KEY=""
USED_FALLBACK=0
IDENT_SOURCE=""
IDENT=""
MARKER=""
STABLE_ANCHOR=""
KEY_SOURCE=""
ADOPTED_FROM=""
CANDIDATE_LIST=""
CANDIDATE_KEYS=""
CANDIDATE_KEY_COUNT=0
PRESERVED_ANCHOR=""
REWRITE_MARKER=1

RAW_SID="${CLAUDE_SESSION_ID:-}"
if [ -n "$RAW_SID" ]; then
  # Same sanitize shape the hooks use: anything outside the filesystem-safe set
  # becomes `_`, so a session id can never escape the handoffs directory.
  SESSION_KEY="$(printf '%s' "$RAW_SID" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
fi

# An id made only of separators (e.g. "///") sanitizes to a non-empty but
# meaningless key, so treat a value with no alphanumeric character as absent
# rather than letting two such ids share a log.
case "$SESSION_KEY" in
  *[A-Za-z0-9]*) : ;;
  *) SESSION_KEY="" ;;
esac

if [ -z "$SESSION_KEY" ]; then
  USED_FALLBACK=1

  IDENT="${ISSUE_MAKER_CONV_ID:-}"
  IDENT_SOURCE="override"
  if [ -z "$IDENT" ]; then
    IDENT="$(conversation_identity)"
    IDENT_SOURCE="claude-ancestor"
  fi
  if [ -z "$IDENT" ]; then
    # No `claude` ancestor — not a Claude Code Bash tool call. The parent
    # process is the best remaining identity, but it is only as stable as the
    # caller's own shell, so say so instead of pretending otherwise.
    IDENT="ppid=${PPID:-0}|start=$(ps -o lstart= -p "${PPID:-0}" 2>/dev/null | tr -s ' ' || true)"
    IDENT_SOURCE="parent-process"
  fi

  STABLE_ANCHOR="$(stable_anchor)"

  IDENT_DIGEST="$(digest "$IDENT")" || no_digest_tool
  MARKER="$MARKER_DIR/imk-${IDENT_DIGEST}"

  if [ -r "$MARKER" ]; then
    SESSION_KEY="$(marker_key "$MARKER")"
  fi

  # A marker that does not hold a well-formed key is treated as absent and
  # re-minted. Reusing a corrupt value would put the batch in an unpredictable
  # file — the very failure mode this script exists to remove.
  case "$SESSION_KEY" in
    fallback-[0-9a-f]*) : ;;
    *) SESSION_KEY="" ;;
  esac

  if [ -n "$SESSION_KEY" ]; then
    KEY_SOURCE="marker"
    REWRITE_MARKER=1
    # An invocation that cannot derive an anchor must never ERASE the one this
    # marker already records — that would silently cost the conversation its
    # drift recovery, and the loss would only surface at the next drift. A
    # derivable anchor still wins: it is the current truth for this
    # conversation.
    if [ -z "$STABLE_ANCHOR" ]; then
      PRESERVED_ANCHOR="$(marker_field "$MARKER" anchor)"
      if [ -n "$PRESERVED_ANCHOR" ]; then
        STABLE_ANCHOR="$PRESERVED_ANCHOR"
        # …and it must not write that anchor BACK either. We learned it from
        # this very marker, so re-recording it carries no new information — only
        # an epoch bump. The write is not free: write_marker is an unlocked
        # read-modify-write, so a concurrent invocation that recorded a NEWER
        # anchor between our read and our write would be silently reverted to
        # the old one, and the next ancestor drift would find no marker under
        # the true anchor and mint the sibling log this change exists to
        # prevent. With nothing of our own to record, the safe write is none.
        REWRITE_MARKER=0
      fi
    fi
    # Record the anchor and a fresh epoch on the marker we just used. This is
    # the only path that upgrades a pre-#1572 one-line marker — which records no
    # anchor at all, so the preserve branch above cannot fire and the write
    # always runs there — and an already-running conversation becomes
    # drift-recoverable from here on.
    [ "$REWRITE_MARKER" -eq 0 ] || write_marker
  else
    # Exact miss. Before minting, look for THIS conversation's existing log:
    # an ancestor chain that changed mid-conversation lands here, and minting
    # would strand the batch on a brand-new empty sibling (issue #1572).
    if [ -n "$STABLE_ANCHOR" ]; then
      adopt_from_anchor
    fi
  fi

  if [ -z "$SESSION_KEY" ]; then
    CWD="$(pwd -P 2>/dev/null || printf '%s' "${PWD:-}")"
    KEY_DIGEST="$(digest "${IDENT}|cwd=${CWD}")" || no_digest_tool
    SESSION_KEY="fallback-${KEY_DIGEST}"
    KEY_SOURCE="minted"
    publish_marker
  elif [ "$KEY_SOURCE" = "adopted" ]; then
    # Point the drifted identity at the adopted key so the next call in this
    # conversation takes the exact-digest fast path instead of re-scanning.
    publish_marker
  fi
fi

LOG="$HANDOFF_DIR/issue-maker-${SESSION_KEY}-log.json"

if [ "$MODE" = key ]; then
  printf '%s\n' "$SESSION_KEY"
  exit 0
fi

if [ "$USED_FALLBACK" -eq 1 ]; then
  warn "NOTE: CLAUDE_SESSION_ID is unset — /issue-maker derived the per-conversation key '$SESSION_KEY' from $IDENT_SOURCE (marker: $MARKER). This replaces the shared 'default' log that collided across sessions (issue #1369)."
  if [ "$IDENT_SOURCE" = "parent-process" ]; then
    warn "WARN: no 'claude' ancestor process was found, so the key is derived from this shell's parent. It is unique per caller but NOT guaranteed stable across invocations — verify the log path before relying on a recovered batch."
  fi
  if [ "$KEY_SOURCE" = "adopted" ]; then
    # More than one distinct key under one anchor is genuinely ambiguous: say
    # which markers disagree and which one won, and mint nothing (issue #1572).
    if [ "$CANDIDATE_KEY_COUNT" -gt 1 ]; then
      warn "WARN: several markers record this conversation's anchor '$STABLE_ANCHOR' with DIFFERENT keys — $CANDIDATE_LIST. Adopted '$SESSION_KEY' (newest recorded epoch; lexicographically smallest key on a tie) and minted nothing. Inspect the losing log(s) by hand before any batch-wide write."
    else
      warn "NOTE: this conversation's ancestor identity changed (sleep/wake or a harness reconnect), so /issue-maker kept its ORIGINAL key '$SESSION_KEY' — adopted from $ADOPTED_FROM via anchor '$STABLE_ANCHOR' — instead of minting a sibling log (issue #1572)."
    fi
  fi
fi

# Collision backstop — the log exists but records a different session key.
# Reaching this means two conversations resolved the same path, which is the
# #1369 failure itself; say so rather than writing into it silently.
#
# The read status is kept SEPARATE from the value. Folding a failed read into
# an empty session_id would make the three states that matter — "no owner
# recorded", "the file is corrupt", "jq is missing" — indistinguishable, and
# the backstop would go quiet in exactly the cases where ownership is least
# verifiable. An unverifiable log gets a warning of its own instead.
if [ -f "$LOG" ]; then
  if EXISTING_SID="$(jq -r '.session_id // ""' "$LOG" 2>/dev/null)"; then
    if [ -n "$EXISTING_SID" ] && [ "$EXISTING_SID" != "$SESSION_KEY" ]; then
      warn "WARN: $LOG records session_id '$EXISTING_SID' but this conversation resolved '$SESSION_KEY' — another session may be writing to this log. Do NOT run batch-wide writes against it; start a fresh capture thread."
    fi
  else
    warn "WARN: could not read session_id from $LOG — it is unreadable or not valid JSON, or jq is unavailable. Ownership could NOT be verified, so the collision backstop did not run. Inspect the log by hand before any batch-wide write."
  fi
fi

# A pre-#1369 shared log is never adopted automatically: that sharing IS the
# bug. Point at it so a batch captured under the old scheme is not silently
# lost, and let the operator move it across deliberately.
LEGACY_LOG="$HANDOFF_DIR/issue-maker-default-log.json"
if [ "$USED_FALLBACK" -eq 1 ] && [ ! -f "$LOG" ] && [ -f "$LEGACY_LOG" ]; then
  warn "NOTE: a pre-#1369 shared log exists at $LEGACY_LOG. It is NOT adopted automatically — copy across only the entries this conversation owns."
fi

printf '%s\n' "$LOG"
