#!/usr/bin/env bash
# Offline tests for checkpoint-handoff.sh (issue #941).
#
# The interesting property under test is the DEGRADE LADDER: the script must
# produce a document that passes portable-handoff-lint.sh in whatever repository
# it happens to run in, including this one — where the changed-file list is full
# of `.claude/…` paths the lint rejects outright. So the suite builds two
# throwaway repositories, one with ordinary filenames and one with harness-shaped
# ones, and asserts that the first lists files while the second silently drops to
# a count — both linting clean.
#
# It also pins the contract with the consumer: usage-limit-record.sh must find a
# checkpoint through its existing glob and publish a non-null portable_handoff.
# That is the whole point of the feature, and it is the assertion most likely to
# rot if either filename convention drifts.
#
# Requires git and jq. Run from repo root:
#   bash .claude/scripts/tests/checkpoint-handoff.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/hooks/checkpoint-handoff.sh"
LINT="$REPO_ROOT/.claude/scripts/portable-handoff-lint.sh"
RECORDER="$REPO_ROOT/.claude/hooks/usage-limit-record.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$desc"
  else fail "$desc (expected '$expected', got '$actual')"; fi
}
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"
  else fail "$desc (missing '$needle')"; fi
}
check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$desc"
  else fail "$desc (unexpectedly present: '$needle')"; fi
}

# ---- a self-contained copy of the harness the script resolves against -------
# Laid out exactly as production is — the script under hooks, the checker one
# directory over under scripts — because that split is the whole reason
# resolve_script carries a `../scripts` candidate. A flat fixture would resolve
# through the "own directory" candidate instead and pass while the real layout
# silently fell through to whatever copy the shared worktree happened to hold.
#
# The skills directory is not decoration either: the checker resolves its
# command catalog from <script>/../.., and without one it falls back to an
# over-broad shape rule — so the suite would be exercising a different code path
# than production does.
FAKE="$TMP/harness"
mkdir -p "$FAKE/.claude/hooks" "$FAKE/.claude/scripts" \
         "$FAKE/.claude/skills/wrap" "$FAKE/.claude/skills/stop" \
         "$FAKE/.claude/skills/stop-resume" "$FAKE/.claude/skills/pause" \
         "$FAKE/.claude/skills/pause-resume" "$FAKE/.claude/skills/fixpr"
cp "$SUT" "$FAKE/.claude/hooks/"
cp "$LINT" "$FAKE/.claude/scripts/"
chmod +x "$FAKE/.claude/hooks/"*.sh "$FAKE/.claude/scripts/"*.sh
CP="$FAKE/.claude/hooks/checkpoint-handoff.sh"

# Prove the split layout actually resolves the neighbouring checker before any
# assertion depends on it. Without this, every "passes the portability check"
# result below could be produced by a script that found no checker at all and
# shipped its most conservative rendering unverified — which is a pass for the
# wrong reason, and invisible.
# "Branch:" is the discriminator: only the minimal tier omits it, and the
# no-checker path can accept nothing else. Seeing it therefore proves a checker
# was found AND accepted a richer rendering.
PROBE_REPO="$TMP/probe"
mkdir -p "$PROBE_REPO"
git init -q -b main "$PROBE_REPO"
git -C "$PROBE_REPO" config user.email "test@example.com"
git -C "$PROBE_REPO" config user.name "Test"
echo x > "$PROBE_REPO/plain.txt"
git -C "$PROBE_REPO" add -A
git -C "$PROBE_REPO" commit -qm seed
PROBE_DOC=$(cd "$PROBE_REPO" && "$CP" --stdout --no-remote 2>/dev/null)
check_contains "T0 checker resolved: a richer tier shipped, not the minimal fallback" "Branch: main" "$PROBE_DOC"

new_repo() { # $1 = path
  mkdir -p "$1"
  git init -q -b main "$1"
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
  echo seed > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm "seed"
}

# ---------------------------------------------------------------------------
# T1 — ordinary repository: the richest tier ships, file names and all
# ---------------------------------------------------------------------------
PLAIN="$TMP/plain"
new_repo "$PLAIN"
echo change > "$PLAIN/src-notes.txt"
OUT_PLAIN="$TMP/out-plain"
DOC=$(cd "$PLAIN" && "$CP" --stdout --no-remote --out-dir "$OUT_PLAIN" 2>/dev/null)
check_contains "T1 ordinary repo lists the changed file by name" "src-notes.txt" "$DOC"
printf '%s\n' "$DOC" > "$TMP/t1.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t1.md" >/dev/null 2>&1
check_eq "T1 richest tier passes the portability check" "0" "$?"

# ---------------------------------------------------------------------------
# T2 — harness-shaped repository: the ladder degrades, and still lints clean.
#      This is the case that made the ladder necessary; without it the script
#      would emit a document that fails its own gate every time it ran here.
# ---------------------------------------------------------------------------
HARNESSY="$TMP/harnessy"
new_repo "$HARNESSY"
mkdir -p "$HARNESSY/.claude/scripts"
echo 'echo hi' > "$HARNESSY/.claude/scripts/thing.sh"
OUT_H="$TMP/out-h"
DOC_H=$(cd "$HARNESSY" && "$CP" --stdout --no-remote --out-dir "$OUT_H" 2>/dev/null)
check_not_contains "T2 harness-shaped path is not reproduced in the document" ".claude/scripts/thing.sh" "$DOC_H"
check_contains "T2 degraded tier reports a count instead" "Untracked changes: 1 file(s)" "$DOC_H"
printf '%s\n' "$DOC_H" > "$TMP/t2.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t2.md" >/dev/null 2>&1
check_eq "T2 degraded tier passes the portability check" "0" "$?"

# Required sections and the absolute working directory, asserted directly rather
# than trusting the lint's summary exit code.
for section in "Start here" "What we're working on" "Open work" "Progress and verification" "Decisions made this session" "Local state on this machine" "Resume safely"; do
  check_contains "T2 section present: $section" "## $section" "$DOC_H"
done
WD_LINE=$(printf '%s\n' "$DOC_H" | grep '^Working directory: ' | head -1)
check_eq "T2 working directory is absolute" "1" "$([[ "${WD_LINE#Working directory: }" == /* ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# T3 — publishing: filename matches the glob the recorder already scans
# ---------------------------------------------------------------------------
OUT="$TMP/handoffs"
WROTE=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$OUT" 2>/dev/null)
check_eq "T3 publish exits 0" "0" "$?"
check_eq "T3 wrote exactly one file" "1" "$(find "$OUT" -maxdepth 1 -type f -name 'portable-handoff-*.md' | wc -l | tr -d ' ')"
check_contains "T3 filename carries the checkpoint suffix" "-checkpoint.md" "$WROTE"
check_eq "T3 filename matches the recorder's glob" "1" \
  "$(find "$OUT" -maxdepth 1 -type f -name 'portable-handoff-*.md' | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# T4 — throttle
#
# Asserted on the script's own stdout: it prints the published path when it
# writes and prints nothing when it declines. Counting files in the directory
# was the obvious alternative and is wrong — the filename carries a
# whole-second timestamp, so two writes in the same second land on the same
# name and the count does not move even though both wrote.
#
# Each case seeds its own prior checkpoint with a controlled fingerprint and
# modification time, so nothing here depends on wall-clock timing or a sleep.
# ---------------------------------------------------------------------------
current_fingerprint() { # $1 = repo
  (cd "$1" && "$CP" --stdout --no-remote 2>/dev/null) | grep -o 'checkpoint-fingerprint: [0-9a-f]*' | head -1
}
seed_checkpoint() { # $1 = dir, $2 = fingerprint line, $3 = optional touch stamp
  mkdir -p "$1"
  local f="$1/portable-handoff-20260101T000000Z-seed-checkpoint.md"
  printf 'seeded\n<!-- %s -->\n' "$2" > "$f"
  [[ -n "${3:-}" ]] && touch -t "$3" "$f"
  printf '%s' "$f"
}

FP=$(current_fingerprint "$PLAIN")
check_eq "T4 fingerprint is readable from the rendered document" "1" \
  "$([[ -n "$FP" ]] && echo 1 || echo 0)"

T4A="$TMP/t4a"; seed_checkpoint "$T4A" "$FP" >/dev/null
OUT_A=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$T4A" 2>/dev/null)
check_eq "T4 unchanged state inside the window writes nothing" "" "$OUT_A"

T4B="$TMP/t4b"; seed_checkpoint "$T4B" "checkpoint-fingerprint: 0000000000000000" >/dev/null
OUT_B=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$T4B" 2>/dev/null)
check_contains "T4 changed state inside the window still writes" "-checkpoint.md" "$OUT_B"

T4C="$TMP/t4c"; seed_checkpoint "$T4C" "$FP" "202501010000" >/dev/null
OUT_C=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$T4C" 2>/dev/null)
check_contains "T4 elapsed window writes even with unchanged state" "-checkpoint.md" "$OUT_C"

T4D="$TMP/t4d"; seed_checkpoint "$T4D" "$FP" >/dev/null
OUT_D=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$T4D" --force 2>/dev/null)
check_contains "T4 --force overrides the throttle" "-checkpoint.md" "$OUT_D"

# ---------------------------------------------------------------------------
# T5 — back-pointer to a hand-written handoff
# ---------------------------------------------------------------------------
OUT_BP="$TMP/handoffs-bp"
mkdir -p "$OUT_BP"
RICH="$OUT_BP/portable-handoff-20260101T000000Z-abc123.md"
echo "a hand-written handoff" > "$RICH"
DOC_BP=$(cd "$PLAIN" && "$CP" --stdout --no-remote --out-dir "$OUT_BP" 2>/dev/null)
check_contains "T5 names the hand-written handoff by basename" "portable-handoff-20260101T000000Z-abc123.md" "$DOC_BP"
check_not_contains "T5 does not print its unportable absolute path" "$OUT_BP/portable-handoff" "$DOC_BP"
printf '%s\n' "$DOC_BP" > "$TMP/t5.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t5.md" >/dev/null 2>&1
check_eq "T5 back-pointer rendering still passes the portability check" "0" "$?"

# A checkpoint must never be advertised as the hand-written one.
DOC_BP2=$(cd "$PLAIN" && "$CP" --stdout --no-remote --out-dir "$OUT" 2>/dev/null)
check_not_contains "T5 an existing checkpoint is not offered as the hand-written handoff" "-checkpoint.md\`" "$DOC_BP2"

# ---------------------------------------------------------------------------
# T6 — retention prunes only what this script wrote
# ---------------------------------------------------------------------------
OUT_R="$TMP/handoffs-retention"
mkdir -p "$OUT_R"
OLD_CP="$OUT_R/portable-handoff-20250101T000000Z-old-checkpoint.md"
OLD_RICH="$OUT_R/portable-handoff-20250101T000000Z-old.md"
echo old > "$OLD_CP"
echo old > "$OLD_RICH"
touch -t 202501010000 "$OLD_CP" "$OLD_RICH"
(cd "$PLAIN" && "$CP" --no-remote --out-dir "$OUT_R" --retention-days 7 >/dev/null 2>&1)
check_eq "T6 stale checkpoint pruned" "0" "$([[ -f "$OLD_CP" ]] && echo 1 || echo 0)"
check_eq "T6 hand-written handoff of the same age survives" "1" "$([[ -f "$OLD_RICH" ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# T7 — the consumer contract: the recorder finds a checkpoint
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  REC_DIR="$TMP/rec"
  mkdir -p "$REC_DIR"
  PAYLOAD='{"session_id":"s1","cwd":"/tmp","transcript_path":"/tmp/t.jsonl","error":"rate_limit","error_details":"limit","last_assistant_message":"working"}'
  OUT_REC="$TMP/handoffs-rec"
  mkdir -p "$OUT_REC"
  (cd "$PLAIN" && "$CP" --no-remote --out-dir "$OUT_REC" --min-interval 0 >/dev/null 2>&1)
  printf '%s' "$PAYLOAD" | CLAUDE_USAGE_LIMIT_DIR="$REC_DIR" CLAUDE_HANDOFF_DIR="$OUT_REC" bash "$RECORDER" >/dev/null 2>&1
  PH=$(jq -r '.portable_handoff // "null"' "$REC_DIR/usage-limit-last.json" 2>/dev/null)
  check_eq "T7 recorder publishes a non-null portable_handoff" "1" "$([[ "$PH" != "null" && -n "$PH" ]] && echo 1 || echo 0)"
  check_contains "T7 recorder points at the checkpoint this script wrote" "-checkpoint.md" "$PH"
else
  echo "skip — T7 needs jq"
fi

# ---------------------------------------------------------------------------
# T9 — pull request records: an empty title must not shift the fields
#
# The fields are joined by US (0x1f) rather than a tab precisely because tab is
# IFS whitespace and `read` collapses runs of it — with a tab, a titleless pull
# request silently renders its URL as its title and leaves the URL line empty,
# with nothing failing anywhere. A stub `gh` on PATH is what makes this
# reachable offline; the real one would need a titleless open pull request.
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '42\037\037https://example.com/42\037auerbachb\037REVIEW_REQUIRED\037CLEAN\n'
printf '43\037A real title\037https://example.com/43\037someone-else\037APPROVED\037BEHIND\n'
STUB
chmod +x "$STUB_BIN/gh"
DOC_PR=$(cd "$PLAIN" && PATH="$STUB_BIN:$PATH" "$CP" --stdout --out-dir "$TMP/out-pr" 2>/dev/null)
check_contains "T9 titleless pull request renders without a title" "- **Pull request 42**" "$DOC_PR"
check_contains "T9 titleless pull request keeps its URL" "https://example.com/42" "$DOC_PR"
check_not_contains "T9 the URL never lands in the title position" "Pull request 42 — https" "$DOC_PR"
check_contains "T9 a titled pull request still shows its title" "- **Pull request 43 — A real title**" "$DOC_PR"

# The three fields issue #912 made mandatory, asserted on VALUE and not merely
# on the anchor. The rules themselves can only see presence — "Owner: yes"
# passes them — so presence is exactly the part already covered by the lint
# call below, and the part worth pinning here is that each line carries what
# the forge actually reported.
check_contains "T9 owner comes from the reported author" "Owner: auerbachb" "$DOC_PR"
check_contains "T9 owner is per-entry, not copied between entries" "Owner: someone-else" "$DOC_PR"
check_contains "T9 an undecided pull request says a review is outstanding" "Waiting on: a review — nobody has recorded a decision yet" "$DOC_PR"
check_contains "T9 approval reflects the reported decision" "Approval: not approved yet" "$DOC_PR"
check_contains "T9 an approved pull request says so" "Approval: approved" "$DOC_PR"
# An approved pull request that is BEHIND is waiting on the rebase, not on
# review — merge state has to outrank review decision or the document tells the
# reader to wait for something that already happened.
check_contains "T9 a BEHIND branch outranks its approval in what it waits on" "Waiting on: the branch needs updating against the main branch first" "$DOC_PR"
check_contains "T9 a verification command is offered" "Verify with: gh pr checks 42" "$DOC_PR"
printf '%s\n' "$DOC_PR" > "$TMP/t9.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t9.md" >/dev/null 2>&1
check_eq "T9 pull request rendering passes the portability check" "0" "$?"

# ---------------------------------------------------------------------------
# T10 — review findings from PR #944, each pinned against its own regression
# ---------------------------------------------------------------------------

# (a) A failed pull-request lookup must not render as "none open". The stub
#     exits non-zero with no output, which is byte-identical to a genuinely
#     empty result — the exit code is the only thing separating them.
FAILBIN="$TMP/failbin"; mkdir -p "$FAILBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN/gh"; chmod +x "$FAILBIN/gh"
DOC_FAIL=$(cd "$PLAIN" && PATH="$FAILBIN:$PATH" "$CP" --stdout --out-dir "$TMP/out-ghfail" 2>/dev/null)
check_contains "T10a a failed lookup says it could not be read" "COULD NOT BE READ" "$DOC_FAIL"
check_not_contains "T10a a failed lookup never claims none are open" "No open pull requests were recorded" "$DOC_FAIL"
printf '%s\n' "$DOC_FAIL" > "$TMP/t10a.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t10a.md" >/dev/null 2>&1
check_eq "T10a the could-not-read rendering still passes the portability check" "0" "$?"

# A skipped lookup is a third state and must not borrow either other wording.
DOC_SKIP=$(cd "$PLAIN" && "$CP" --stdout --no-remote --out-dir "$TMP/out-ghskip" 2>/dev/null)
check_contains "T10a a skipped lookup says it was not looked up" "were not looked up" "$DOC_SKIP"

# (b) Branch-name issue detection must not match an embedded number.
git -C "$PLAIN" checkout -q -b reissue-941
DOC_RE=$(cd "$PLAIN" && "$CP" --stdout --no-remote --out-dir "$TMP/out-reissue" 2>/dev/null)
check_not_contains "T10b reissue-941 does not publish an issue 941 link" "/issues/941" "$DOC_RE"
git -C "$PLAIN" checkout -q -b issue-941-real
DOC_REAL=$(cd "$PLAIN" && "$CP" --stdout --no-remote --out-dir "$TMP/out-realissue" 2>/dev/null)
check_contains "T10b issue-941-real still detects issue 941" "issue 941" "$DOC_REAL"
git -C "$PLAIN" checkout -q main

# (c) Staging a change must move the fingerprint. Pre-fix the status columns
#     were stripped before hashing, so `git add` was invisible and the throttle
#     suppressed the checkpoint for the rest of the interval.
echo staged-content > "$PLAIN/stage-me.txt"
FP_UNSTAGED=$(current_fingerprint "$PLAIN")
git -C "$PLAIN" add stage-me.txt
FP_STAGED=$(current_fingerprint "$PLAIN")
check_eq "T10c staging a file changes the fingerprint" "0" \
  "$([[ -n "$FP_UNSTAGED" && "$FP_UNSTAGED" != "$FP_STAGED" ]] && echo 0 || echo 1)"
git -C "$PLAIN" reset -q

# (d) Two writers in the same second must not overwrite each other. Same stamp,
#     same (unset) session id — pre-fix both resolved to one filename and `mv -f`
#     destroyed the first. An account-wide limit fails every session at once, so
#     this is the expected case, not a rare interleave.
OUT_RACE="$TMP/out-race"
A=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$OUT_RACE" --force 2>/dev/null)
B=$(cd "$PLAIN" && "$CP" --no-remote --out-dir "$OUT_RACE" --force 2>/dev/null)
check_eq "T10d two same-second writes produce two distinct files" "0" \
  "$([[ -n "$A" && -n "$B" && "$A" != "$B" ]] && echo 0 || echo 1)"
check_eq "T10d both survive on disk" "2" \
  "$(find "$OUT_RACE" -maxdepth 1 -type f -name '*-checkpoint.md' | wc -l | tr -d ' ')"
check_contains "T10d the unique name still matches the recorder's glob" "-checkpoint.md" "$B"

# (e) A directory basename is only a display label. Outside a checkout it must
#     neither become a malformed GitHub issue URL nor give `gh` permission to
#     use unrelated ambient/default repository context.
NOTREPO_REVIEW="$TMP/notrepo-review"
mkdir -p "$NOTREPO_REVIEW"
DOC_NOTREPO_REMOTE=$(cd "$NOTREPO_REVIEW" && PATH="$STUB_BIN:$PATH" "$CP" --stdout --out-dir "$TMP/out-notrepo-review" 2>/dev/null)
check_not_contains "T10e outside a checkout no unrelated pull requests are reported" "Pull request 42" "$DOC_NOTREPO_REMOTE"
check_contains "T10e outside a checkout the pull-request lookup is skipped" "were not looked up" "$DOC_NOTREPO_REMOTE"

NO_ORIGIN="$TMP/issue-941-no-origin"
new_repo "$NO_ORIGIN"
git -C "$NO_ORIGIN" checkout -q -b issue-941-real
DOC_NO_ORIGIN=$(cd "$NO_ORIGIN" && "$CP" --stdout --no-remote --out-dir "$TMP/out-no-origin" 2>/dev/null)
check_contains "T10e a no-origin branch can still name its issue number" "issue 941" "$DOC_NO_ORIGIN"
check_not_contains "T10e a basename never becomes a malformed GitHub issue URL" "https://github.com/issue-941-no-origin/issues/941" "$DOC_NO_ORIGIN"

# (f) An unborn repository has no HEAD, but a staged file is still tracked
#     takeover state and must not disappear into a failed `git diff HEAD` call.
UNBORN="$TMP/unborn"
mkdir -p "$UNBORN"
git init -q -b main "$UNBORN"
git -C "$UNBORN" config user.email "test@example.com"
git -C "$UNBORN" config user.name "Test"
echo staged >"$UNBORN/staged.txt"
git -C "$UNBORN" add staged.txt
DOC_UNBORN=$(cd "$UNBORN" && "$CP" --stdout --no-remote --out-dir "$TMP/out-unborn" 2>/dev/null)
check_contains "T10f unborn HEAD preserves staged tracked work" "Tracked changes: 1 file(s) — staged.txt" "$DOC_UNBORN"
check_contains "T10f unborn repository keeps its initialized branch" "Branch: main" "$DOC_UNBORN"
check_contains "T10f unborn repository reports that no commit exists" "HEAD commit: unknown — no commits yet" "$DOC_UNBORN"
check_not_contains "T10f unborn repository is not mislabeled outside Git" "HEAD commit: unknown — not a git checkout" "$DOC_UNBORN"
printf '%s\n' "$DOC_UNBORN" >"$TMP/t10f.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t10f.md" >/dev/null 2>&1
check_eq "T10f unborn repository rendering passes portability lint" "0" "$?"

# (g) The degraded tier must give an executable unborn-repository command too.
#     A harness-shaped staged path forces the count-only rendering.
UNBORN_DEGRADED="$TMP/unborn-degraded"
mkdir -p "$UNBORN_DEGRADED/.claude/scripts"
git init -q -b main "$UNBORN_DEGRADED"
git -C "$UNBORN_DEGRADED" config user.email "test@example.com"
git -C "$UNBORN_DEGRADED" config user.name "Test"
echo 'echo staged' >"$UNBORN_DEGRADED/.claude/scripts/staged.sh"
git -C "$UNBORN_DEGRADED" add .claude/scripts/staged.sh
DOC_UNBORN_DEGRADED=$(cd "$UNBORN_DEGRADED" && "$CP" --stdout --no-remote --out-dir "$TMP/out-unborn-degraded" 2>/dev/null)
check_contains "T10g degraded unborn guidance uses the index" 'Tracked changes: 1 file(s); run `git diff --cached --name-only`.' "$DOC_UNBORN_DEGRADED"
check_not_contains "T10g degraded unborn guidance never requires HEAD" 'git diff --name-only HEAD' "$DOC_UNBORN_DEGRADED"
check_contains "T10g degraded unborn repository keeps its initialized branch" "Branch: main" "$DOC_UNBORN_DEGRADED"
check_contains "T10g degraded unborn repository reports that no commit exists" "HEAD commit: unknown — no commits yet" "$DOC_UNBORN_DEGRADED"
check_not_contains "T10g degraded unborn repository is not mislabeled outside Git" "HEAD commit: unknown — not a git checkout" "$DOC_UNBORN_DEGRADED"
printf '%s\n' "$DOC_UNBORN_DEGRADED" >"$TMP/t10g.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t10g.md" >/dev/null 2>&1
check_eq "T10g degraded unborn rendering passes portability lint" "0" "$?"

# ---------------------------------------------------------------------------
# T8 — degraded environments must never fail the turn
# ---------------------------------------------------------------------------
NOTREPO="$TMP/notrepo"
mkdir -p "$NOTREPO"
(cd "$NOTREPO" && "$CP" --no-remote --out-dir "$TMP/out-notrepo" >/dev/null 2>&1)
check_eq "T8 non-repo working directory exits 0" "0" "$?"
DOC_NR=$(cd "$NOTREPO" && "$CP" --stdout --no-remote --out-dir "$TMP/out-notrepo" 2>/dev/null)
check_contains "T8 non-repo document says so plainly" "not a git checkout" "$DOC_NR"
printf '%s\n' "$DOC_NR" > "$TMP/t8.md"
"$LINT" --repo-root "$FAKE" --quiet "$TMP/t8.md" >/dev/null 2>&1
check_eq "T8 non-repo document still passes the portability check" "0" "$?"

# jq absent: only the background-unit count depends on it, and its absence must
# cost that line, not the document.
NOJQ_BIN="$TMP/nojq"
mkdir -p "$NOJQ_BIN"
# `env` and `bash` are on this list on purpose: the script's shebang is
# `#!/usr/bin/env bash`, so omitting either makes the run die at exec with 127 —
# a "missing jq" test that never reached the script at all, and reported the
# failure it was written to rule out.
for b in env bash git find date mktemp mv rm ln sed grep basename dirname cut sort wc stat touch cat chmod uname shasum cksum tr head; do
  src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$NOJQ_BIN/$b"
done
check_eq "T8 jq really is absent from the stripped path" "0" \
  "$(PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1 && echo 1 || echo 0)"
(cd "$PLAIN" && PATH="$NOJQ_BIN" "$CP" --no-remote --out-dir "$TMP/out-nojq" --min-interval 0 >/dev/null 2>&1)
check_eq "T8 missing jq exits 0" "0" "$?"

(cd "$PLAIN" && "$CP" --no-remote --out-dir "$TMP/out-badenv" --min-interval nonsense --retention-days nonsense >/dev/null 2>&1)
check_eq "T8 non-numeric settings exit 0" "0" "$?"

(cd "$PLAIN" && "$CP" --definitely-not-a-flag >/dev/null 2>&1)
check_eq "T8 unknown option exits 0" "0" "$?"

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
