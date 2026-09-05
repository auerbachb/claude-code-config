#!/usr/bin/env bash
# diff-survival-check.sh — Verify a rebase / conflict resolution did not vaporize
# catalog: review-threads-diffs — Verify a rebase or conflict resolution did not vaporize the branch's own diff
# the branch's own diff (issue #757).
#
# Manual conflict re-resolution is the riskiest moment in the whole flow. Git is
# satisfied by ANY resolution without conflict markers — including one that
# simply kept the other side. A resolution can therefore be clean, marker-free,
# green in CI, and yet contain none of the change the PR exists to deliver. The
# failure is silent and passes every existing gate; the cost is discovering
# after merge that the fix never shipped.
#
# This script closes that hole with a snapshot/verify pair:
#
#   snapshot — BEFORE the rebase/merge starts, record which files the branch
#              meaningfully changes against its base.
#   verify   — AFTER the resolution, confirm the branch still does something and
#              that every file which carried a substantive change before still
#              carries one. If not: block, name the files, and stop.
#
# It NEVER repairs, stages, commits, pushes, or otherwise touches the working
# tree — it only reads and compares. A failed verify is an UNRESOLVED conflict,
# never a success.
#
# Whitespace awareness: "substantive" means the file appears in `git diff -w`.
# A file whose pre-operation change was real but whose post-resolution change
# survives only as re-indentation counts as LOST, so indent-heavy PRs cannot
# false-pass.
#
# Rename handling: every diff is taken with `--no-renames`, so a rename appears
# as delete-old + add-new on BOTH sides of the comparison. A resolution that
# moves a file therefore keeps the old path in the post-operation set and is not
# misreported as a loss.
#
# Snapshot home: `git rev-parse --git-path claude-diff-survival.json` — the
# WORKTREE's git dir (`.git/worktrees/<name>/…` for a linked worktree). That
# location survives session interruption (the incident that motivated this
# guard was a resumed session inheriting a poisoned resolution), travels with
# the worktree, is never tracked, and sits deliberately outside the
# session-state / handoff mechanisms. Safe to delete at any time (`clear`).
#
# Pre-operation head resolution for `snapshot`, in priority order:
#   1. --head <ref>, when given.
#   2. An in-progress rebase's `orig-head` — the pre-rebase branch tip. This is
#      what lets /go-on snapshot a rebase a previous session already started:
#      mid-rebase HEAD is the PARTIALLY REPLAYED tree, i.e. exactly the poisoned
#      state being tested for, so it must never be used as the baseline.
#   3. HEAD.
#
# Usage:
#   diff-survival-check.sh snapshot [--base <ref>] [--head <ref>] [--if-absent] [--json]
#   diff-survival-check.sh verify   [--base <ref>] [--json]
#   diff-survival-check.sh status   [--json]
#   diff-survival-check.sh clear
#   diff-survival-check.sh --help
#
# --base <ref>   Base to diff against. Default: origin/main, falling back to
#                main when origin/main does not resolve (this is also what keeps
#                the unit test fully offline). `verify` reuses the snapshot's
#                recorded base unless --base overrides it.
# --head <ref>   Override the pre-operation head (see resolution order above).
# --if-absent    `snapshot` only: keep an existing snapshot instead of
#                overwriting it. Resume paths use this so a snapshot taken
#                before the operation always wins over one reconstructed after.
# --json         Emit a single-line JSON object instead of human-readable lines.
#
# Post-operation state selection for `verify`:
#   * unmerged paths present  → exit 4; there is nothing to verify yet.
#   * rebase in progress      → base = `onto`,      diff = index (`--cached`).
#   * merge in progress       → base = MERGE_HEAD,  diff = index (`--cached`).
#   * clean tree              → base = merge-base(HEAD, base_ref), diff vs HEAD.
#
# Deferred verdict: when a rebase still has commits queued in its todo list, the
# branch's contribution is only partly replayed, so a missing file is expected
# rather than lost. `verify` then reports verdict `deferred` and exits 0. Call
# sites run the real gate after `git rebase --continue` completes and BEFORE the
# force-push, where nothing is pending.
#
# Output (single-line JSON with --json; human-readable lines otherwise):
#   snapshot: {"op":"snapshot","branch":"…","pre_head":"…","base_ref":"origin/main",
#              "base_sha":"…","source":"head|rebase-orig-head|explicit",
#              "substantive_files":[…],"whitespace_only_files":[…],
#              "all_files":[…],"pre_diff_empty":false,"snapshot_path":"…"}
#   verify:   {"op":"verify","verdict":"intact|deferred|vanished|files_lost|unverifiable|
#                                       unresolved_conflicts|branch_mismatch|no_snapshot",
#              "lost_files":[…],"post_state":"rebase|merge|clean",
#              "pending_commits":0,"base_ref":"…","base_sha":"…",
#              "stale_snapshot":false,"message":"…"}
#   status:   {"op":"status","present":true|false,"snapshot_path":"…", …snapshot}
#
# Exit codes:
#   0 — intact (or deferred / snapshot written / status printed / cleared)
#   1 — the entire diff vanished: nothing substantive survives against the base
#   2 — specific files lost their changes (named on stdout)
#   3 — usage error
#   4 — git / tooling error, snapshot-vs-branch mismatch, unresolved conflicts
#       still present, or `unverifiable` (the snapshot's baseline commit IS the
#       commit being verified, so the comparison proves nothing — a baseline
#       cannot be reconstructed after an operation has already finished)
#   5 — `verify` with no snapshot on disk
#
# NOTE: verdicts own 0/1/2 as issue #757 specifies, so usage and tooling errors
# move to 3/4 rather than the repo's more usual "2 = usage".

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SNAPSHOT_NAME="claude-diff-survival.json"
SNAPSHOT_VERSION=1
STALE_AFTER_SECS=86400

print_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() { echo "ERROR: $1" >&2; exit 3; }
die_env()   { echo "ERROR: $1" >&2; exit 4; }

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
OP=""
BASE_FLAG=""
HEAD_FLAG=""
IF_ABSENT=false
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    snapshot|verify|status|clear)
      [[ -n "$OP" ]] && die_usage "only one operation may be given (already have '$OP', got '$1')"
      OP="$1"; shift ;;
    --base)
      [[ -z "${2:-}" ]] && die_usage "--base requires a ref"
      BASE_FLAG="$2"; shift 2 ;;
    --head)
      [[ -z "${2:-}" ]] && die_usage "--head requires a ref"
      HEAD_FLAG="$2"; shift 2 ;;
    --if-absent) IF_ABSENT=true; shift ;;
    --json)      JSON=true; shift ;;
    -*) die_usage "unknown flag: $1" ;;
    *)  die_usage "unexpected argument: $1" ;;
  esac
done

[[ -z "$OP" ]] && { echo "ERROR: an operation is required (snapshot|verify|status|clear)" >&2; print_usage >&2; exit 3; }
if [[ "$OP" != "snapshot" ]]; then
  [[ -n "$HEAD_FLAG" ]] && die_usage "--head is only valid with 'snapshot'"
  [[ "$IF_ABSENT" == true ]] && die_usage "--if-absent is only valid with 'snapshot'"
fi
[[ "$OP" == "clear" && -n "$BASE_FLAG" ]] && die_usage "--base is not valid with 'clear'"

command -v jq >/dev/null 2>&1 || die_env "jq is required but not installed."
git rev-parse --git-dir >/dev/null 2>&1 || die_env "not a git repository (or no work tree)."

# --------------------------------------------------------------------------
# Git-state helpers
# --------------------------------------------------------------------------
git_path() { git rev-parse --git-path "$1"; }

SNAPSHOT_PATH="$(git_path "$SNAPSHOT_NAME")"

REBASE_DIR=""
if [[ -d "$(git_path rebase-merge)" ]]; then
  REBASE_DIR="$(git_path rebase-merge)"
elif [[ -d "$(git_path rebase-apply)" ]]; then
  REBASE_DIR="$(git_path rebase-apply)"
fi

MERGE_IN_PROGRESS=false
[[ -f "$(git_path MERGE_HEAD)" ]] && MERGE_IN_PROGRESS=true

# Branch identity. Mid-rebase HEAD is detached, so recover the name git stashed
# in the rebase state rather than reporting an empty branch (which would make
# the snapshot-vs-branch guard misfire on every resumed rebase).
current_branch() {
  local b
  b="$(git branch --show-current 2>/dev/null)"
  if [[ -z "$b" && -n "$REBASE_DIR" && -f "$REBASE_DIR/head-name" ]]; then
    b="$(cat "$REBASE_DIR/head-name" 2>/dev/null)"
    b="${b#refs/heads/}"
  fi
  printf '%s' "$b"
}

# Commits still queued for replay. Non-zero means the branch's contribution is
# only partly applied, so an absent file is expected rather than lost.
pending_commits() {
  local n=0
  if [[ -n "$REBASE_DIR" ]]; then
    if [[ -f "$REBASE_DIR/git-rebase-todo" ]]; then
      # awk, not `grep -c`: grep exits 1 on a zero count, so `|| echo 0` would
      # append a second "0" to grep's own "0" and break the numeric test below.
      # A lone `noop` is git's placeholder for "nothing left to replay".
      n="$(awk '!/^[[:space:]]*(#|$)/ && !/^[[:space:]]*noop[[:space:]]*$/ { c++ } END { print c + 0 }' "$REBASE_DIR/git-rebase-todo" 2>/dev/null)"
    elif [[ -f "$REBASE_DIR/next" && -f "$REBASE_DIR/last" ]]; then
      local next last
      next="$(cat "$REBASE_DIR/next" 2>/dev/null || echo 0)"
      last="$(cat "$REBASE_DIR/last" 2>/dev/null || echo 0)"
      [[ "$next" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] && n=$(( last - next )) || n=0
      [[ "$n" -lt 0 ]] && n=0
    fi
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

resolve_commit() { git rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null; }

# Default base: origin/main, falling back to main. An explicit --base is used
# verbatim so an offline/local ref works (the unit test relies on this).
resolve_base_ref() {
  local want="${1:-}"
  if [[ -n "$want" ]]; then
    resolve_commit "$want" >/dev/null || die_env "cannot resolve base ref '$want'."
    printf '%s' "$want"; return 0
  fi
  local c
  for c in origin/main main; do
    if resolve_commit "$c" >/dev/null; then printf '%s' "$c"; return 0; fi
  done
  die_env "cannot resolve a default base ref (tried origin/main, main) — pass --base <ref>."
}

# Changed-path sets. --no-renames keeps both sides of the comparison symmetric
# (a rename is delete-old + add-new on both), so a moved file never reads as
# lost. `-z` avoids git's path quoting; a path containing a literal newline is
# out of scope (git cannot represent one unquoted either).
names_raw() { git diff --no-renames --name-only -z "$@" 2>/dev/null | tr '\0' '\n'; }

# Substantive = the file still differs once whitespace is ignored. NOTE: this
# CANNOT use `git diff -w --name-only` — that combination still lists
# whitespace-only files (git computes the name list from the tree filepair, not
# from the whitespace-aware textual diff), which would silently defeat the
# whitespace-awareness contract. `--quiet` does honour -w: exit 0 = no
# non-whitespace difference, exit 1 = a real one. Anything else is a git error;
# treat the file as substantive so ambiguity never resolves toward "fine".
names_substantive() {
  local f rc
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rc=0
    git diff -w --no-renames --quiet "$@" -- "$f" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] && printf '%s\n' "$f"
  done < <(names_raw "$@")
}

to_json_array() {
  if [[ -z "${1:-}" ]]; then echo '[]'; else printf '%s\n' "$1" | jq -R . | jq -cs 'map(select(length > 0)) | unique'; fi
}

read_snapshot_field() { jq -r "$1" < "$SNAPSHOT_PATH" 2>/dev/null; }

# --------------------------------------------------------------------------
# clear
# --------------------------------------------------------------------------
if [[ "$OP" == "clear" ]]; then
  if [[ -f "$SNAPSHOT_PATH" ]]; then
    rm -f "$SNAPSHOT_PATH" || die_env "could not remove $SNAPSHOT_PATH"
    echo "[diff-survival] snapshot cleared ($SNAPSHOT_PATH)"
  else
    echo "[diff-survival] no snapshot to clear ($SNAPSHOT_PATH)"
  fi
  exit 0
fi

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
if [[ "$OP" == "status" ]]; then
  if [[ -f "$SNAPSHOT_PATH" ]] && jq -e . >/dev/null 2>&1 < "$SNAPSHOT_PATH"; then
    if [[ "$JSON" == true ]]; then
      jq -c --arg p "$SNAPSHOT_PATH" '{op:"status", present:true, snapshot_path:$p} + .' < "$SNAPSHOT_PATH"
    else
      echo "[diff-survival] snapshot present: $SNAPSHOT_PATH"
      echo "[diff-survival]   branch=$(read_snapshot_field '.branch // ""') pre_head=$(read_snapshot_field '.pre_head // ""' | cut -c1-12) base=$(read_snapshot_field '.base_ref // ""') captured_at=$(read_snapshot_field '.captured_at // ""')"
      echo "[diff-survival]   substantive files: $(read_snapshot_field '.substantive_files | length')"
    fi
  else
    if [[ "$JSON" == true ]]; then
      jq -cn --arg p "$SNAPSHOT_PATH" '{op:"status", present:false, snapshot_path:$p}'
    else
      echo "[diff-survival] no snapshot present ($SNAPSHOT_PATH)"
    fi
  fi
  exit 0
fi

# --------------------------------------------------------------------------
# snapshot
# --------------------------------------------------------------------------
if [[ "$OP" == "snapshot" ]]; then
  if [[ "$IF_ABSENT" == true && -f "$SNAPSHOT_PATH" ]] && jq -e . >/dev/null 2>&1 < "$SNAPSHOT_PATH"; then
    if [[ "$JSON" == true ]]; then
      jq -c --arg p "$SNAPSHOT_PATH" '{op:"snapshot", kept_existing:true, snapshot_path:$p} + .' < "$SNAPSHOT_PATH"
    else
      echo "[diff-survival] existing snapshot kept (--if-absent): $SNAPSHOT_PATH"
      echo "[diff-survival]   captured_at=$(read_snapshot_field '.captured_at // ""') substantive files: $(read_snapshot_field '.substantive_files | length')"
    fi
    exit 0
  fi

  SOURCE="head"
  if [[ -n "$HEAD_FLAG" ]]; then
    PRE_HEAD="$(resolve_commit "$HEAD_FLAG")" || true
    [[ -z "${PRE_HEAD:-}" ]] && die_env "cannot resolve --head ref '$HEAD_FLAG'."
    SOURCE="explicit"
  elif [[ -n "$REBASE_DIR" && -f "$REBASE_DIR/orig-head" ]]; then
    PRE_HEAD="$(resolve_commit "$(cat "$REBASE_DIR/orig-head")")" || true
    [[ -z "${PRE_HEAD:-}" ]] && die_env "rebase in progress but its orig-head does not resolve."
    SOURCE="rebase-orig-head"
  else
    PRE_HEAD="$(resolve_commit HEAD)" || true
    [[ -z "${PRE_HEAD:-}" ]] && die_env "cannot resolve HEAD — is this an empty repository?"
  fi

  BASE_REF="$(resolve_base_ref "$BASE_FLAG")" || exit $?
  BASE_SHA="$(git merge-base "$PRE_HEAD" "$BASE_REF" 2>/dev/null)"
  [[ -z "$BASE_SHA" ]] && die_env "no merge base between $PRE_HEAD and $BASE_REF."

  ALL="$(names_raw "$BASE_SHA" "$PRE_HEAD")"
  SUB="$(names_substantive "$BASE_SHA" "$PRE_HEAD")"
  ALL_JSON="$(to_json_array "$ALL")"
  SUB_JSON="$(to_json_array "$SUB")"
  WS_JSON="$(jq -cn --argjson a "$ALL_JSON" --argjson s "$SUB_JSON" '$a - $s')"
  PRE_EMPTY=false
  [[ "$(jq 'length' <<<"$ALL_JSON")" -eq 0 ]] && PRE_EMPTY=true

  BRANCH="$(current_branch)"
  SNAP_JSON="$(jq -cn \
    --argjson version "$SNAPSHOT_VERSION" \
    --arg captured_at "$(date -u +%FT%TZ)" \
    --arg branch "$BRANCH" \
    --arg pre_head "$PRE_HEAD" \
    --arg base_ref "$BASE_REF" \
    --arg base_sha "$BASE_SHA" \
    --arg source "$SOURCE" \
    --argjson substantive_files "$SUB_JSON" \
    --argjson whitespace_only_files "$WS_JSON" \
    --argjson all_files "$ALL_JSON" \
    --argjson pre_diff_empty "$PRE_EMPTY" \
    '{version:$version, captured_at:$captured_at, branch:$branch, pre_head:$pre_head,
      base_ref:$base_ref, base_sha:$base_sha, source:$source,
      substantive_files:$substantive_files, whitespace_only_files:$whitespace_only_files,
      all_files:$all_files, pre_diff_empty:$pre_diff_empty}')"

  TMP="$(mktemp "${SNAPSHOT_PATH}.XXXXXX")" || die_env "could not create a temp file next to $SNAPSHOT_PATH"
  printf '%s\n' "$SNAP_JSON" > "$TMP" && mv -f "$TMP" "$SNAPSHOT_PATH" || {
    rm -f "$TMP" 2>/dev/null
    die_env "could not write the snapshot to $SNAPSHOT_PATH"
  }

  if [[ "$JSON" == true ]]; then
    jq -cn --argjson s "$SNAP_JSON" --arg p "$SNAPSHOT_PATH" '{op:"snapshot", snapshot_path:$p} + $s'
  else
    echo "[diff-survival] snapshot captured — branch=${BRANCH:-<detached>} pre_head=${PRE_HEAD:0:12} base=$BASE_REF (${BASE_SHA:0:12}) source=$SOURCE"
    echo "[diff-survival]   $(jq 'length' <<<"$SUB_JSON") file(s) with substantive changes, $(jq 'length' <<<"$WS_JSON") whitespace-only"
    if [[ "$SOURCE" == "head" && -z "$REBASE_DIR" && "$MERGE_IN_PROGRESS" != true ]]; then
      echo "[diff-survival]   NOTE: this is a PRE-operation baseline. If the rebase/merge has already finished,"
      echo "[diff-survival]     it describes the post-resolution state and 'verify' will report UNVERIFIABLE"
      echo "[diff-survival]     rather than pass — a baseline cannot be reconstructed after the fact."
    fi
    [[ "$PRE_EMPTY" == true ]] && echo "[diff-survival]   WARNING: the branch had no diff against $BASE_REF at snapshot time — there is nothing to protect."
    echo "[diff-survival]   stored at $SNAPSHOT_PATH"
  fi
  exit 0
fi

# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------
emit_verify() {
  local verdict="$1" lost_json="$2" post_state="$3" pending="$4" base_ref="$5" base_sha="$6" stale="$7" message="$8"
  if [[ "$JSON" == true ]]; then
    jq -cn \
      --arg verdict "$verdict" --argjson lost_files "$lost_json" --arg post_state "$post_state" \
      --argjson pending_commits "$pending" --arg base_ref "$base_ref" --arg base_sha "$base_sha" \
      --argjson stale_snapshot "$stale" --arg message "$message" \
      '{op:"verify", verdict:$verdict, lost_files:$lost_files, post_state:$post_state,
        pending_commits:$pending_commits, base_ref:$base_ref, base_sha:$base_sha,
        stale_snapshot:$stale_snapshot, message:$message}'
  fi
}

if [[ ! -f "$SNAPSHOT_PATH" ]] || ! jq -e . >/dev/null 2>&1 < "$SNAPSHOT_PATH"; then
  # Non-verdict exits still emit a parseable object under --json, so a machine
  # caller never has to distinguish "JSON on stdout" from "prose on stderr".
  emit_verify "no_snapshot" '[]' "unknown" 0 "${BASE_FLAG:-}" "" false \
    "no usable snapshot at $SNAPSHOT_PATH — run 'snapshot' BEFORE the rebase/merge (or 'snapshot --if-absent' mid-rebase)."
  echo "ERROR: no usable diff-survival snapshot at $SNAPSHOT_PATH — run 'diff-survival-check.sh snapshot' BEFORE the rebase/merge." >&2
  exit 5
fi

SNAP_BRANCH="$(read_snapshot_field '.branch // ""')"
SNAP_BASE_REF="$(read_snapshot_field '.base_ref // ""')"
SNAP_SUB_JSON="$(read_snapshot_field '.substantive_files // []' | jq -c . 2>/dev/null || echo '[]')"
SNAP_PRE_EMPTY="$(read_snapshot_field '.pre_diff_empty // false')"
SNAP_CAPTURED="$(read_snapshot_field '.captured_at // ""')"

CUR_BRANCH="$(current_branch)"
if [[ -n "$SNAP_BRANCH" && -n "$CUR_BRANCH" && "$SNAP_BRANCH" != "$CUR_BRANCH" ]]; then
  emit_verify "branch_mismatch" '[]' "unknown" 0 "$SNAP_BASE_REF" "" false \
    "snapshot was taken on branch '$SNAP_BRANCH' but this is '$CUR_BRANCH'."
  echo "ERROR: snapshot was taken on branch '$SNAP_BRANCH' but this is '$CUR_BRANCH' — refusing to compare. Run 'diff-survival-check.sh clear' if the snapshot is stale." >&2
  exit 4
fi

# Staleness is advisory only — an old snapshot is still the best evidence we
# have of what the branch used to change.
STALE=false
if [[ -n "$SNAP_CAPTURED" ]]; then
  CAP_EPOCH="$(python3 -c 'import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$SNAP_CAPTURED" 2>/dev/null || echo "")"
  if [[ -n "$CAP_EPOCH" ]]; then
    NOW_EPOCH="$(date -u +%s)"
    [[ $(( NOW_EPOCH - CAP_EPOCH )) -gt "$STALE_AFTER_SECS" ]] && STALE=true
  fi
fi

# An unmerged path means the resolution is not finished; there is no post-op
# state to judge yet, and reporting "lost" here would be noise.
UNMERGED="$(git diff --name-only --diff-filter=U 2>/dev/null)"
if [[ -n "$UNMERGED" ]]; then
  emit_verify "unresolved_conflicts" "$(to_json_array "$UNMERGED")" "unknown" "$(pending_commits)" "${BASE_FLAG:-$SNAP_BASE_REF}" "" "$STALE" \
    "unresolved conflicts remain — finish the resolution, then re-run verify."
  echo "ERROR: unresolved conflicts remain in:" >&2
  while IFS= read -r u; do [[ -n "$u" ]] && printf '  %s\n' "$u" >&2; done <<<"$UNMERGED"
  echo "ERROR: finish the resolution first, then re-run 'diff-survival-check.sh verify'." >&2
  exit 4
fi

BASE_REF_EFF="${BASE_FLAG:-$SNAP_BASE_REF}"
PENDING="$(pending_commits)"

if [[ -n "$REBASE_DIR" ]]; then
  POST_STATE="rebase"
  if [[ -f "$REBASE_DIR/onto" ]]; then
    POST_BASE="$(resolve_commit "$(cat "$REBASE_DIR/onto")")" || true
  fi
  [[ -z "${POST_BASE:-}" ]] && POST_BASE="$(resolve_commit "$(resolve_base_ref "$BASE_REF_EFF")")"
  [[ -z "${POST_BASE:-}" ]] && die_env "rebase in progress but its target commit does not resolve."
  POST_RAW="$(names_raw --cached "$POST_BASE")"
  POST_SUB="$(names_substantive --cached "$POST_BASE")"
elif [[ "$MERGE_IN_PROGRESS" == true ]]; then
  POST_STATE="merge"
  # head -1: an octopus merge records one SHA per line; the first is enough to
  # answer "what does this branch add on top of what it is merging in".
  POST_BASE="$(resolve_commit "$(head -1 "$(git_path MERGE_HEAD)")")" || true
  [[ -z "${POST_BASE:-}" ]] && die_env "merge in progress but MERGE_HEAD does not resolve."
  POST_RAW="$(names_raw --cached "$POST_BASE")"
  POST_SUB="$(names_substantive --cached "$POST_BASE")"
else
  POST_STATE="clean"
  BASE_REF_RESOLVED="$(resolve_base_ref "$BASE_REF_EFF")" || exit $?
  POST_BASE="$(git merge-base HEAD "$BASE_REF_RESOLVED" 2>/dev/null)"
  [[ -z "$POST_BASE" ]] && die_env "no merge base between HEAD and $BASE_REF_RESOLVED."
  POST_RAW="$(names_raw "$POST_BASE" HEAD)"
  POST_SUB="$(names_substantive "$POST_BASE" HEAD)"
fi

POST_RAW_JSON="$(to_json_array "$POST_RAW")"
POST_SUB_JSON="$(to_json_array "$POST_SUB")"
SNAP_SUB_COUNT="$(jq 'length' <<<"$SNAP_SUB_JSON")"

# --- Deferred: a partly-replayed rebase cannot be judged yet. ----------------
if [[ "$POST_STATE" == "rebase" && "$PENDING" -gt 0 ]]; then
  MSG="rebase still has $PENDING commit(s) queued for replay — re-run verify after 'git rebase --continue' completes and before the force-push."
  emit_verify "deferred" '[]' "$POST_STATE" "$PENDING" "$BASE_REF_EFF" "$POST_BASE" "$STALE" "$MSG"
  [[ "$JSON" == true ]] || echo "[diff-survival] deferred — $MSG"
  exit 0
fi

# --- Tautology guard: the baseline IS the state being judged. ---------------
# A snapshot taken on a clean tree AFTER an operation already finished records
# the post-resolution state as its own baseline, so every later comparison is
# `X vs X` and returns intact — including via pre_diff_empty. That would let a
# vaporized branch sail through the guard, which is the exact failure this
# script exists to catch. Refuse rather than render a verdict the evidence
# cannot support.
if [[ "$POST_STATE" == "clean" ]]; then
  CUR_HEAD="$(resolve_commit HEAD)"
  SNAP_PRE_HEAD="$(read_snapshot_field '.pre_head // ""')"
  if [[ -n "$CUR_HEAD" && "$CUR_HEAD" == "$SNAP_PRE_HEAD" ]]; then
    MSG="the snapshot's baseline commit is the very commit being verified (${CUR_HEAD:0:12}) — this comparison proves nothing."
    emit_verify "unverifiable" '[]' "$POST_STATE" "$PENDING" "$BASE_REF_EFF" "$POST_BASE" "$STALE" "$MSG"
    if [[ "$JSON" != true ]]; then
      echo "[diff-survival] UNVERIFIABLE — $MSG"
      echo "[diff-survival] Most likely the snapshot was taken AFTER the resolution finished. A post-hoc baseline"
      echo "[diff-survival]   cannot distinguish a preserved diff from a vaporized one — treat the resolution as"
      echo "[diff-survival]   UNVERIFIED and unresolved, and say so; do not report it as clean."
      echo "[diff-survival] If instead the operation was a genuine no-op (nothing to rebase), nothing changed —"
      echo "[diff-survival]   'clear' the snapshot and take a fresh one before the real operation."
    fi
    exit 4
  fi
fi

# --- Nothing was ever at risk. ----------------------------------------------
if [[ "$SNAP_PRE_EMPTY" == "true" ]]; then
  MSG="the branch had no diff against its base at snapshot time — nothing to protect."
  emit_verify "intact" '[]' "$POST_STATE" "$PENDING" "$BASE_REF_EFF" "$POST_BASE" "$STALE" "$MSG"
  [[ "$JSON" == true ]] || echo "[diff-survival] intact — $MSG"
  exit 0
fi

# --- Vanished: nothing substantive survives against the base. ---------------
POST_RAW_COUNT="$(jq 'length' <<<"$POST_RAW_JSON")"
POST_SUB_COUNT="$(jq 'length' <<<"$POST_SUB_JSON")"
if [[ "$POST_RAW_COUNT" -eq 0 || ( "$POST_SUB_COUNT" -eq 0 && "$SNAP_SUB_COUNT" -gt 0 ) ]]; then
  if [[ "$POST_RAW_COUNT" -eq 0 ]]; then
    MSG="the branch's entire diff against $BASE_REF_EFF is empty after the resolution — every change the PR existed to deliver is gone."
  else
    MSG="the branch's diff against $BASE_REF_EFF survives only as whitespace — every substantive change is gone."
  fi
  emit_verify "vanished" '[]' "$POST_STATE" "$PENDING" "$BASE_REF_EFF" "$POST_BASE" "$STALE" "$MSG"
  if [[ "$JSON" != true ]]; then
    echo "[diff-survival] VANISHED — $MSG"
    echo "[diff-survival] Do NOT commit or force-push this resolution. Treat it as an unresolved conflict."
    echo "[diff-survival] One legitimate case: main independently gained the identical change, so the PR is genuinely empty."
    echo "[diff-survival]   If that is what happened, CLOSE the PR — do not force-push an empty branch."
    echo "[diff-survival] Otherwise recover the pre-operation state yourself (e.g. 'git rebase --abort', or reset to ORIG_HEAD) and redo the resolution."
    echo "[diff-survival] This check never repairs anything — it only blocks and reports."
    [[ "$STALE" == true ]] && echo "[diff-survival] NOTE: snapshot is older than 24h (captured $SNAP_CAPTURED) — confirm it still describes this operation."
  fi
  exit 1
fi

# --- Files lost: present-and-substantive before, not substantive now. -------
LOST_JSON="$(jq -cn --argjson snap "$SNAP_SUB_JSON" --argjson post "$POST_SUB_JSON" '$snap - $post')"
LOST_COUNT="$(jq 'length' <<<"$LOST_JSON")"
if [[ "$LOST_COUNT" -gt 0 ]]; then
  MSG="$LOST_COUNT file(s) carried substantive changes before the operation and no longer do."
  emit_verify "files_lost" "$LOST_JSON" "$POST_STATE" "$PENDING" "$BASE_REF_EFF" "$POST_BASE" "$STALE" "$MSG"
  if [[ "$JSON" != true ]]; then
    echo "[diff-survival] LOST — $MSG"
    jq -r '.[] | "  " + .' <<<"$LOST_JSON"
    echo "[diff-survival] Do NOT commit or force-push this resolution. Treat it as an unresolved conflict."
    echo "[diff-survival] A file whose change survives only as whitespace counts as lost — re-apply the real change to each file above."
    echo "[diff-survival] This check never repairs anything — it only blocks and reports."
    [[ "$STALE" == true ]] && echo "[diff-survival] NOTE: snapshot is older than 24h (captured $SNAP_CAPTURED) — confirm it still describes this operation."
  fi
  exit 2
fi

MSG="all $SNAP_SUB_COUNT substantive file(s) from the pre-operation diff still carry changes against $BASE_REF_EFF."
emit_verify "intact" '[]' "$POST_STATE" "$PENDING" "$BASE_REF_EFF" "$POST_BASE" "$STALE" "$MSG"
[[ "$JSON" == true ]] || echo "[diff-survival] intact — $MSG"
exit 0
