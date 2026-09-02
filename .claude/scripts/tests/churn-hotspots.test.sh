#!/usr/bin/env bash
# Offline tests for churn-hotspots.sh (issue #755).
#
# Fully hermetic: builds real temp git repos with squash-style subjects, stubs
# `gh` on PATH, and points HOME at a temp dir so session-state reads are seeded
# rather than inherited. No network access.
#
# Run from repo root: bash .claude/scripts/tests/churn-hotspots.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/churn-hotspots.sh"

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

check_eq() {  # desc, expected, actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

check_jq() {  # desc, json, jq boolean expr
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

# ---- gh stub ----------------------------------------------------------------
# Matches on a single stable token per case — never on --json field order, which
# changes as callers add fields. Unhandled invocations exit 1 loudly.
#
# `issue list` is the one exception: it honours `--state` (issue #915). The bug
# being guarded against is a SERVER-SIDE state filter, so a stub that returned
# every fixture row regardless of the flag would let an open-only lookup pass
# the closed-match tests — a guard that passes by not running. Filtering here
# means those tests fail on `--state open` and pass on `--state all`.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  *"repo view"*)      cat "$TMP/repo_view.txt" ;;
  *"issue list"*)
    case "\$args" in
      # A fixture row with no "state" field stands in for an open issue. The
      # type guard keeps a deliberately malformed fixture (non-string state)
      # from aborting the stub itself rather than the code under test.
      *"--state open"*)   jq -c 'def s: (if type == "string" then ascii_upcase else "OPEN" end); [.[] | select((.state | s) != "CLOSED")]' "$TMP/issue_list.json" ;;
      *"--state closed"*) jq -c 'def s: (if type == "string" then ascii_upcase else "OPEN" end); [.[] | select((.state | s) == "CLOSED")]' "$TMP/issue_list.json" ;;
      *)                  cat "$TMP/issue_list.json" ;;
    esac
    ;;
  *"pr list"*)        cat "$TMP/pr_list.json" ;;
  *"/files"*)
    pr=\$(printf '%s' "\$args" | sed -n 's|.*/pulls/\([0-9][0-9]*\)/files.*|\1|p')
    if [ -f "$TMP/files_\$pr.json" ]; then cat "$TMP/files_\$pr.json"; else printf '[]'; fi
    ;;
  *) echo "gh stub: unhandled args: \$args" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

printf 'testowner/testrepo\n' > "$TMP/repo_view.txt"
printf '[]\n' > "$TMP/issue_list.json"
printf '[]\n' > "$TMP/pr_list.json"

# gh_files <PR> [<status> <path>]... — write the JSON that `pulls/{N}/files`
# returns, one object per status/path pair.
#
# These fixtures hold the API's OWN payload, not the post-`--jq` stream the old
# `files_<PR>.txt` fixtures held. That difference is the point: the detector now
# pipes the raw response through its own jq filter, so a fixture in the old
# shape would stub past the very code that turns a payload into NUL-delimited
# records (issue #1554).
#
# An EMPTY status writes a row with NO `status` key at all — how the real schema
# expresses a payload without one, which must still count as a touch. `--args`
# carries each value through argv, so a path containing a newline or a tab
# reaches the fixture verbatim instead of being re-split by the shell.
gh_files() {  # $1 PR number, then alternating <status> <path> arguments
  local pr="$1"; shift
  jq -nc '[ range(0; ($ARGS.positional | length); 2)
            | { status: $ARGS.positional[.], filename: $ARGS.positional[. + 1] }
            | if .status == "" then del(.status) else . end ]' \
    --args "$@" > "$TMP/files_$pr.json"
}

# ---- helpers ----------------------------------------------------------------
WINDOW_START="2026-01-01"

new_repo() {  # $1 dir name -> echoes path
  local dir="$TMP/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf '%s' "$dir"
}

# Every path a fixture touches is born in a PR-UNMARKED seed commit unless the
# scenario deliberately creates it in-window. Creation commits no longer score
# (issue #1547), so letting the first in-window PR create the file would
# silently turn every unrelated scenario into a test of the creation rule.
#
# The seed date sits INSIDE the window (before every fixture commit date) even
# though the seed is conceptually "before" the history. A pre-window date would
# be correct only if every seed landed at the root: `git log --since` STOPS
# walking a linear history at the first commit older than the cutoff, so a seed
# emitted lazily in the middle of a fixture's history would hide every commit
# beneath it. An unmarked commit contributes nothing either way, so an in-window
# seed is invisible to the detector without truncating the log.
SEED_DATE="2026-01-15T00:00:00"

seed_missing() {  # $1 repo, $2... files
  local repo="$1"; shift
  local f any=0
  for f in "$@"; do
    if [ ! -e "$repo/$f" ]; then
      mkdir -p "$repo/$(dirname "$f")"
      printf 'seed\n' > "$repo/$f"
      git -C "$repo" add "$f"
      any=1
    fi
  done
  [ "$any" -eq 1 ] || return 0
  GIT_AUTHOR_DATE="$SEED_DATE" GIT_COMMITTER_DATE="$SEED_DATE" \
    git -C "$repo" commit -q -m "seed fixture paths"
}

commit_touch() {  # $1 repo, $2 date, $3 subject, $4... files
  local repo="$1" date="$2" subject="$3"; shift 3
  local f
  seed_missing "$repo" "$@"
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    echo "change $date" >> "$repo/$f"
    git -C "$repo" add "$f"
  done
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$repo" commit -q -m "$subject"
}

commit_create() {  # $1 repo, $2 date, $3 subject, $4... files — create IN-window
  local repo="$1" date="$2" subject="$3"; shift 3
  local f
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    printf 'created %s\n' "$date" > "$repo/$f"
    git -C "$repo" add "$f"
  done
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    git -C "$repo" commit -q -m "$subject"
}

run_in() {  # $1 repo, rest: script args -> sets OUT / RC
  local repo="$1"; shift
  OUT=$(cd "$repo" && bash "$SCRIPT" "$@" 2>/dev/null)
  RC=$?
}

new_repo_on() {  # $1 dir name, $2 branch -> echoes path
  # `git init -b` is too new for every runner, and the ambient init.defaultBranch
  # differs per machine — point HEAD at the branch explicitly so the fixtures
  # exercise a KNOWN branch name rather than whatever the host defaults to.
  local dir
  dir=$(new_repo "$1")
  git -C "$dir" symbolic-ref HEAD "refs/heads/$2"
  printf '%s' "$dir"
}

add_origin() {  # $1 repo, $2 bare dir name, $3 branch to publish
  local bare="$TMP/$2"
  git init -q --bare "$bare"
  # A bare repo's HEAD follows the host's ambient init.defaultBranch, which is
  # not necessarily the branch being published. Leaving it stale makes a later
  # `git clone` of this bare repo check out a branch that does not exist — the
  # clone lands with no working tree and no local branch, and the next push
  # fails. Point HEAD at the published branch, which is what a real remote does.
  git -C "$bare" symbolic-ref HEAD "refs/heads/$3"
  git -C "$1" remote add origin "$bare"
  git -C "$1" push -q origin "$3"
  git -C "$1" fetch -q origin
  git -C "$1" symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$3"
}

# =============================================================================
# Scenario 1 — 3 distinct PRs touch one file inside the window
# =============================================================================
R1=$(new_repo r1)
commit_touch "$R1" "2026-02-01T00:00:00" "add form (#201)" src/Form.tsx
commit_touch "$R1" "2026-02-02T00:00:00" "tweak form (#202)" src/Form.tsx
commit_touch "$R1" "2026-02-03T00:00:00" "fix form (#203)" src/Form.tsx src/Other.tsx

run_in "$R1" --since "$WINDOW_START" --json
check_eq "1a: exit 0 when a hotspot is found" "0" "$RC"
check_jq "1b: the churned file is reported" "$OUT" '.hotspots | map(.file) | index("src/Form.tsx") != null'
check_jq "1c: all three PR numbers are attached as evidence" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .pr_numbers == [201,202,203]'
check_jq "1d: pr_count is 3" "$OUT" '.hotspots[] | select(.file=="src/Form.tsx") | .pr_count == 3'
check_jq "1e: a 1-PR file is not a hotspot" "$OUT" '.hotspots | map(.file) | index("src/Other.tsx") == null'
check_jq "1f: score equals pr_count with no conflicts" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .score == 3 and .conflict_rounds == 0'
check_jq "1g: source is the git path" "$OUT" '.source == "git"'
check_jq "1h: merge window bounds are reported" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | (.first_merged_at | startswith("2026-02-01")) and (.last_merged_at | startswith("2026-02-03"))'

# TSV (default) output carries the same evidence
run_in "$R1" --since "$WINDOW_START"
check_eq "1i: TSV row reports path, counts and PR list" \
  "src/Form.tsx	3	0	3	201,202,203	-" "$(printf '%s' "$OUT" | head -1)"

# =============================================================================
# Scenario 2 — below threshold is clean
# =============================================================================
R2=$(new_repo r2)
commit_touch "$R2" "2026-02-01T00:00:00" "one (#301)" src/Solo.tsx
commit_touch "$R2" "2026-02-02T00:00:00" "two (#302)" src/Solo.tsx

run_in "$R2" --since "$WINDOW_START" --json
check_eq "2a: exit 1 when nothing crosses the threshold" "1" "$RC"
check_jq "2b: hotspot list is empty" "$OUT" '.hotspots | length == 0'
check_jq "2c: total_hotspot_count is 0" "$OUT" '.total_hotspot_count == 0'

# ...and the same history IS a hotspot at a lower threshold
run_in "$R2" --since "$WINDOW_START" --threshold 2 --json
check_eq "2d: exit 0 once the threshold is lowered to 2" "0" "$RC"

# =============================================================================
# Scenario 3 — subject carrying both an issue ref and a PR marker
# =============================================================================
R3=$(new_repo r3)
commit_touch "$R3" "2026-02-01T00:00:00" "fix(#749): repair thing (#750)" src/A.ts
commit_touch "$R3" "2026-02-02T00:00:00" "fix(#749): repair more (#751)" src/A.ts
commit_touch "$R3" "2026-02-03T00:00:00" "chore(#700): tidy (#752)" src/A.ts

run_in "$R3" --since "$WINDOW_START" --json
check_jq "3a: the TRAILING (#N) marker is taken as the PR number" "$OUT" \
  '.hotspots[] | select(.file=="src/A.ts") | .pr_numbers == [750,751,752]'
check_jq "3b: the leading issue reference is not counted as a PR" "$OUT" \
  '.hotspots[] | select(.file=="src/A.ts") | (.pr_numbers | index(749)) == null'

# Commits with no PR marker at all contribute nothing
commit_touch "$R3" "2026-02-04T00:00:00" "unmarked direct commit" src/B.ts
commit_touch "$R3" "2026-02-05T00:00:00" "another unmarked commit" src/B.ts
commit_touch "$R3" "2026-02-06T00:00:00" "third unmarked commit" src/B.ts
run_in "$R3" --since "$WINDOW_START" --json
check_jq "3c: unmarked commits never form a hotspot" "$OUT" '.hotspots | map(.file) | index("src/B.ts") == null'

# Non-ASCII paths must come through verbatim. git quotes them by default
# ("src/caf\303\251.ts"), which both mangles the path and wraps it in quotes
# that would corrupt the file key the issue lookup matches on.
R3B=$(new_repo r3b)
commit_touch "$R3B" "2026-02-01T00:00:00" "a (#310)" "src/café.ts"
commit_touch "$R3B" "2026-02-02T00:00:00" "b (#311)" "src/café.ts"
commit_touch "$R3B" "2026-02-03T00:00:00" "c (#312)" "src/café.ts"
run_in "$R3B" --since "$WINDOW_START" --json
check_jq "3d: a non-ASCII path is reported verbatim, unquoted" "$OUT" \
  '.hotspots | map(.file) | index("src/café.ts") != null'

# =============================================================================
# Scenario 4 — conflict rounds carry documented weight
# =============================================================================
# Two PRs (score 2, below the default threshold of 3) plus one recorded
# conflict round at weight 2 => score 4, which crosses.
cat > "$HOME/.claude/session-state.json" <<'EOF'
{"schema_version":1,"repos":{"testowner/testrepo":{"prs":{
  "401":{"babysit":{"conflict_streak":1}},
  "601":{"babysit":{"conflict_streak":3}},
  "701":{"babysit":{"conflict_streak":2},"conflict_rounds":2}
}}}}
EOF

R4=$(new_repo r4)
commit_touch "$R4" "2026-02-01T00:00:00" "first (#401)" src/Hot.tsx
commit_touch "$R4" "2026-02-02T00:00:00" "second (#402)" src/Hot.tsx

run_in "$R4" --since "$WINDOW_START" --repo testowner/testrepo --json
check_eq "4a: conflict weight pushes a 2-PR file over threshold 3" "0" "$RC"
check_jq "4b: conflict_rounds is read from babysit.conflict_streak" "$OUT" \
  '.hotspots[] | select(.file=="src/Hot.tsx") | .conflict_rounds == 1'
check_jq "4c: score = pr_count + weight*rounds" "$OUT" \
  '.hotspots[] | select(.file=="src/Hot.tsx") | .score == 4'
check_jq "4d: the conflicting PR is named as evidence" "$OUT" \
  '.hotspots[] | select(.file=="src/Hot.tsx") | .conflict_prs == [401]'

# A weight of 0 disables the boost entirely
run_in "$R4" --since "$WINDOW_START" --repo testowner/testrepo --conflict-weight 0 --json
check_eq "4e: --conflict-weight 0 drops the file back below threshold" "1" "$RC"

# babysit.conflict_streak and conflict_rounds are maxed, never summed
R4B=$(new_repo r4b)
commit_touch "$R4B" "2026-02-01T00:00:00" "a (#701)" src/Max.tsx
commit_touch "$R4B" "2026-02-02T00:00:00" "b (#702)" src/Max.tsx
run_in "$R4B" --since "$WINDOW_START" --repo testowner/testrepo --json
check_jq "4f: the two conflict fields are maxed, not summed (2, not 4)" "$OUT" \
  '.hotspots[] | select(.file=="src/Max.tsx") | .conflict_rounds == 2'

# =============================================================================
# Scenario 5 — the MIN_PRS floor: conflicts alone never make a hotspot
# =============================================================================
R5=$(new_repo r5)
commit_touch "$R5" "2026-02-01T00:00:00" "solo but conflicted (#601)" src/Lonely.tsx

run_in "$R5" --since "$WINDOW_START" --repo testowner/testrepo --json
check_eq "5a: one PR with 3 conflict rounds is still not multi-PR churn" "1" "$RC"
check_jq "5b: nothing is reported despite a score of 7" "$OUT" '.hotspots | length == 0'
check_jq "5c: the floor is surfaced in the envelope" "$OUT" '.min_prs == 2'

# =============================================================================
# Scenario 6 — fresh clone: no session-state history at all
# =============================================================================
rm -f "$HOME/.claude/session-state.json"
run_in "$R1" --since "$WINDOW_START" --repo testowner/testrepo --json
check_eq "6a: runs with no session-state file present" "0" "$RC"
check_jq "6b: conflict rounds degrade to 0 rather than failing" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .conflict_rounds == 0'
check_jq "6c: PR evidence is unaffected by the missing state" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .pr_numbers == [201,202,203]'

# =============================================================================
# Scenario 7/8/9 — existing hotspot issue lookup (drives file-vs-comment)
#
# A CLOSED match is simulated by a `"state":"CLOSED"` field on the fixture row —
# exactly the shape `--state all` returns (issue #915). The stub applies the
# same state filter GitHub would, so these fixtures only reach the script when
# the lookup actually asks for both states; an open-only lookup never sees the
# closed rows and fails the assertions below, which is the point.
# =============================================================================
printf '[]\n' > "$TMP/issue_list.json"
run_in "$R1" --since "$WINDOW_START" --json
check_jq "7a: no matching issue leaves existing_hotspot_issue null (file path)" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == null'
check_jq "7b: a successful empty lookup is not a failure" "$OUT" '.existing_lookup_failed == false'
check_jq "7c: the state field is always emitted, null when there is no match" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx")
   | has("existing_hotspot_issue_state") and .existing_hotspot_issue_state == null'

cat > "$TMP/issue_list.json" <<'EOF'
[{"number":900,"title":"Refactor hotspot: src/Form.tsx","body":"evidence","state":"OPEN"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8a: an exact title match populates existing_hotspot_issue (comment path)" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 900'
check_jq "8b: an open match reports state open" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue_state == "open"'

# Body marker alone is enough, even when the title was edited by a human
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":901,"title":"Split the giant form component","body":"context\n<!-- churn-hotspot: src/Form.tsx -->\n","state":"OPEN"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8c: the body marker matches even after a title edit" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 901 and .existing_hotspot_issue_state == "open"'

# A CLOSED match is REPORTED, not dropped (issue #915). Under the old open-only
# lookup this read as `null` — a blank slate — so /wrap re-filed the hotspot on
# every wrap, silently overturning the owner's decision to close it.
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":904,"title":"Refactor hotspot: src/Form.tsx","body":"adjudicated","state":"CLOSED"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8d: a closed match is reported rather than read as no-issue" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 904'
check_jq "8e: a closed match reports state closed" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue_state == "closed"'

# TSV must not let a closed-issue hotspot read as already handled
run_in "$R1" --since "$WINDOW_START"
check_eq "8f: TSV suffixes a closed match with (closed)" \
  "src/Form.tsx	3	0	3	201,202,203	904 (closed)" "$(printf '%s' "$OUT" | head -1)"

# Both states present for one path: the OPEN one wins. That preference is what
# stops the re-file loop — once /wrap re-files a closed hotspot, the new open
# issue becomes the chosen match on the next run instead of the closed one.
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":905,"title":"Refactor hotspot: src/Form.tsx","body":"older, adjudicated","state":"CLOSED"},
 {"number":906,"title":"Refactor hotspot: src/Form.tsx","body":"the live one","state":"OPEN"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8g: an open match wins over a closed one for the same path" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 906 and .existing_hotspot_issue_state == "open"'

# ...and the preference holds regardless of which one the search returned first
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":907,"title":"Refactor hotspot: src/Form.tsx","body":"the live one","state":"OPEN"},
 {"number":908,"title":"Refactor hotspot: src/Form.tsx","body":"older, adjudicated","state":"CLOSED"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8h: open still wins when it is listed first" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 907 and .existing_hotspot_issue_state == "open"'

# An unrecognized state reports `"unknown"`, never null and never a dropped
# match. Null is reserved for "no match at all" — overloading it here would let
# a consumer branching on `state == null` read a matched hotspot as a blank
# slate, which is this ticket's own bug in miniature.
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":909,"title":"Refactor hotspot: src/Form.tsx","body":"unreadable state","state":"ARCHIVED"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8i: an unreadable state reports the number with state unknown, not null" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 909 and .existing_hotspot_issue_state == "unknown"'
run_in "$R1" --since "$WINDOW_START"
check_eq "8j: TSV suffixes an unknown-state match with (unknown)" \
  "src/Form.tsx	3	0	3	201,202,203	909 (unknown)" "$(printf '%s' "$OUT" | head -1)"

# A non-string state must not abort the whole jq program: its failure mode is an
# EMPTY hotspot list under exit 0, so one malformed row would lose every hotspot.
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":910,"title":"Refactor hotspot: src/Form.tsx","body":"numeric state","state":404}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8k: a non-string state degrades that row without emptying the report" "$OUT" \
  '(.hotspots | length) > 0
   and (.hotspots[] | select(.file=="src/Form.tsx")
        | .existing_hotspot_issue == 910 and .existing_hotspot_issue_state == "unknown")'

# Near-miss titles must NOT match — GitHub tokenizes paths, exact match is the guard
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":902,"title":"Refactor hotspot: src/OtherForm.tsx","body":"different file","state":"OPEN"},
 {"number":903,"title":"Refactor hotspot: src/Form.tsx.bak","body":"different file","state":"CLOSED"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "9a: a sibling-file hotspot issue does not match" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == null and .existing_hotspot_issue_state == null'

# A capped issue lookup is an INCOMPLETE lookup: a matching issue may sit beyond
# the cap, so absence of a match no longer proves absence of an issue. Callers
# gate filing on existing_lookup_failed, so the cap must set it — reporting only
# `truncated` would let a caller file a duplicate. `--state all` enlarges the
# candidate set, so the fixture mixes both states: closed issues alone can now
# fill the cap, which is why this guard matters more after #915, not less.
python3 - "$TMP/issue_list.json" <<'PY'
import json, sys
# 200 non-matching issues == ISSUE_LOOKUP_CAP, so the lookup is capped out.
json.dump([{"number": 1000 + i, "title": "Refactor hotspot: src/Unrelated%d.ts" % i, "body": "",
            "state": "OPEN" if i % 2 else "CLOSED"}
           for i in range(200)], open(sys.argv[1], "w"))
PY
run_in "$R1" --since "$WINDOW_START" --json
check_jq "9b: a capped issue lookup sets existing_lookup_failed" "$OUT" '.existing_lookup_failed == true'
check_jq "9c: a capped issue lookup is also reported as truncated" "$OUT" '.truncated == true'
printf '[]\n' > "$TMP/issue_list.json"

# =============================================================================
# Scenario 10 — default exclusions
# =============================================================================
R10=$(new_repo r10)
commit_touch "$R10" "2026-02-01T00:00:00" "deps (#501)" package-lock.json src/Real.ts
commit_touch "$R10" "2026-02-02T00:00:00" "deps (#502)" package-lock.json src/Real.ts
commit_touch "$R10" "2026-02-03T00:00:00" "deps (#503)" package-lock.json src/Real.ts

printf '[]\n' > "$TMP/issue_list.json"
run_in "$R10" --since "$WINDOW_START" --json
check_jq "10a: lockfiles are excluded by default" "$OUT" '.hotspots | map(.file) | index("package-lock.json") == null'
check_jq "10b: real source files in the same commits still register" "$OUT" \
  '.hotspots | map(.file) | index("src/Real.ts") != null'
check_jq "10c: excluded paths are counted, not hidden" "$OUT" '.excluded_count > 0'

run_in "$R10" --since "$WINDOW_START" --no-default-excludes --json
check_jq "10d: --no-default-excludes brings the lockfile back" "$OUT" \
  '.hotspots | map(.file) | index("package-lock.json") != null'

run_in "$R10" --since "$WINDOW_START" --exclude 'src/*' --json
check_jq "10e: --exclude drops a matching path" "$OUT" '.hotspots | map(.file) | index("src/Real.ts") == null'

# =============================================================================
# Scenario 11 — gh enumeration path (the "gh data alone" contract)
# =============================================================================
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":801,"mergedAt":"2026-02-01T00:00:00Z"},
 {"number":802,"mergedAt":"2026-02-02T00:00:00Z"},
 {"number":803,"mergedAt":"2026-02-03T00:00:00Z"},
 {"number":804,"mergedAt":"2020-01-01T00:00:00Z"}]
EOF
# No `status` key on any of these rows — the status-less payload shape, which
# must still enumerate rather than being silently dropped (11a-11i below).
gh_files 801 '' src/Api.ts '' README.md
gh_files 802 '' src/Api.ts
gh_files 803 '' src/Api.ts
gh_files 804 '' src/Api.ts

R11=$(new_repo r11)
commit_touch "$R11" "2026-02-01T00:00:00" "unmarked local commit" src/Ignored.ts
# The gh stub reports src/Api.ts, README.md, and src/Edge.ts. The file_present
# check uses a working-tree test on the gh path (SCAN_REF=""), so these files
# must exist on disk. They are created here via an unmarked commit (no trailing
# (#N) PR marker), which keeps the git-path PR-attribution tests unaffected.
commit_touch "$R11" "2026-02-02T00:00:00" "add stub fixture files" \
  src/Api.ts README.md src/Edge.ts

run_in "$R11" --since "$WINDOW_START" --source gh --json
check_eq "11a: gh-only enumeration finds the hotspot" "0" "$RC"
check_jq "11b: source is reported as gh" "$OUT" '.source == "gh"'
check_jq "11c: PR evidence comes from the gh files endpoint" "$OUT" \
  '.hotspots[] | select(.file=="src/Api.ts") | .pr_numbers == [801,802,803]'
check_jq "11d: a PR merged outside the window is excluded" "$OUT" \
  '.hotspots[] | select(.file=="src/Api.ts") | (.pr_numbers | index(804)) == null'

# auto falls through to gh when git history carries no PR markers
run_in "$R11" --since "$WINDOW_START" --json
check_jq "11e: --source auto falls back to gh on an unmarked history" "$OUT" '.source == "gh"'

# The window is day-granular on BOTH paths. --since is a calendar date (ET-anchored
# via gh-window.sh) while mergedAt is a UTC instant, so comparing against a
# T00:00:00Z stamp made the gh path's window disagree with `git log --since` for
# the same input. A PR merged LATE on the boundary day must be included.
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":811,"mergedAt":"2026-03-01T23:59:00Z"},
 {"number":812,"mergedAt":"2026-03-02T00:30:00Z"},
 {"number":813,"mergedAt":"2026-03-03T12:00:00Z"},
 {"number":814,"mergedAt":"2026-02-28T23:59:00Z"}]
EOF
for n in 811 812 813 814; do gh_files "$n" '' src/Edge.ts; done
run_in "$R11" --since "2026-03-01" --source gh --json
check_jq "11f: a PR merged late on the boundary day is inside the window" "$OUT" \
  '.hotspots[] | select(.file=="src/Edge.ts") | (.pr_numbers | index(811)) != null'
check_jq "11g: the day before the boundary is still excluded" "$OUT" \
  '.hotspots[] | select(.file=="src/Edge.ts") | (.pr_numbers | index(814)) == null'
check_jq "11h: exactly the three in-window PRs are counted" "$OUT" \
  '.hotspots[] | select(.file=="src/Edge.ts") | .pr_numbers == [811,812,813]'

# A git ref resolves --since to a timestamp carrying a LOCAL offset (e.g.
# 2026-03-01T18:00:00-05:00). String-comparing that against UTC `Z` instants is
# unsound: lexicographically "2026-03-01T18:00:00-05:00" > "2026-03-01T12:00:00Z"
# even though the UTC instant 12:00Z is LATER than 18:00-05:00 (= 23:00Z is not,
# but 12:00Z vs 23:00Z shows the ordering flip). Comparing date-to-date removes
# the offset from the comparison entirely.
R11B=$(new_repo r11b)
commit_touch "$R11B" "2026-03-01T18:00:00" "boundary marker commit" src/Anchor.ts
# Capture the anchor by SHA immediately — a relative HEAD~1 would name whichever
# bookkeeping commit the fixture helpers happen to create next.
REF_SHA=$(git -C "$R11B" rev-parse HEAD)
# The gh stub reports src/Ref.ts; the working-tree existence check requires it.
commit_touch "$R11B" "2026-03-01T18:01:00" "add stub fixture file" src/Ref.ts
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":821,"mergedAt":"2026-03-01T12:00:00Z"},
 {"number":822,"mergedAt":"2026-03-01T20:00:00Z"},
 {"number":823,"mergedAt":"2026-03-04T09:00:00Z"}]
EOF
for n in 821 822 823; do gh_files "$n" '' src/Ref.ts; done
run_in "$R11B" --since "$REF_SHA" --source gh --json
check_jq "11i: a git-ref --since counts every PR merged on that calendar day" "$OUT" \
  '.hotspots[] | select(.file=="src/Ref.ts") | .pr_numbers == [821,822,823]'

# =============================================================================
# Scenario 12 — --top bounds output without hiding the total
# =============================================================================
R12=$(new_repo r12)
for pr in 1 2 3; do
  commit_touch "$R12" "2026-02-0${pr}T00:00:00" "change (#$((900 + pr)))" src/One.ts src/Two.ts src/Three.ts
done

printf '[]\n' > "$TMP/issue_list.json"
run_in "$R12" --since "$WINDOW_START" --json
check_jq "12a: all three files are hotspots without --top" "$OUT" '.hotspots | length == 3'

run_in "$R12" --since "$WINDOW_START" --top 1 --json
check_eq "12b: --top still exits 0" "0" "$RC"
check_jq "12c: --top bounds the reported list" "$OUT" '.hotspots | length == 1'
check_jq "12d: total_hotspot_count keeps the full pre-bound figure" "$OUT" '.total_hotspot_count == 3'

# =============================================================================
# Scenario 13 — usage and argument handling
# =============================================================================
(cd "$R1" && bash "$SCRIPT" --bogus >/dev/null 2>&1); check_eq "13a: unknown flag exits 2" "2" "$?"
(cd "$R1" && bash "$SCRIPT" --threshold >/dev/null 2>&1); check_eq "13b: missing value exits 2" "2" "$?"
(cd "$R1" && bash "$SCRIPT" --threshold abc >/dev/null 2>&1); check_eq "13c: non-numeric threshold exits 2" "2" "$?"
(cd "$R1" && bash "$SCRIPT" --source bogus >/dev/null 2>&1); check_eq "13d: invalid --source exits 2" "2" "$?"
(cd "$R1" && bash "$SCRIPT" --help >/dev/null 2>&1); check_eq "13e: --help exits 0" "0" "$?"

# --flag=value form is accepted alongside --flag value
run_in "$R1" --since="$WINDOW_START" --threshold=3 --json
check_eq "13f: --flag=value form is accepted" "0" "$RC"

# --since accepts a git ref, not just a date
REF_SHA=$(git -C "$R1" rev-list --max-parents=0 HEAD | head -1)
run_in "$R1" --since "$REF_SHA" --json
check_eq "13g: --since accepts a git ref/SHA" "0" "$RC"

run_in "$R1" --since "not-a-ref-or-date" --json
check_eq "13h: an unresolvable --since exits 3" "3" "$RC"

# =============================================================================
# Scenario 14 — the scan is scoped to the default branch, not the invoking
# worktree's HEAD (issue #861)
# =============================================================================
# Shape of every /wrap invocation: main carries the squash commits, while the
# feature branch that invokes the script forked earlier and carries an
# unsquashed commit whose subject has only a LEADING (#N) issue reference.
R14=$(new_repo_on r14 main)
commit_touch "$R14" "2026-02-01T00:00:00" "feat(#100): seed (#900)" src/Churn.ts
git -C "$R14" checkout -q -b feature
commit_touch "$R14" "2026-02-02T00:00:00" "docs(#838): stale unsquashed work" src/Churn.ts src/Branch.ts
git -C "$R14" checkout -q main
commit_touch "$R14" "2026-02-03T00:00:00" "fix(#101): more (#901)" src/Churn.ts
commit_touch "$R14" "2026-02-04T00:00:00" "chore(#102): more (#902)" src/Churn.ts
git -C "$R14" checkout -q feature

run_in "$R14" --since "$WINDOW_START" --json
check_eq "14a: a hotspot on main is found while HEAD is a feature branch" "0" "$RC"
check_jq "14b: PR evidence comes from main, including commits the branch never saw" "$OUT" \
  '.hotspots[] | select(.file=="src/Churn.ts") | .pr_numbers == [900,901,902]'
check_jq "14c: the branch's leading (#838) issue ref is never read as a PR" "$OUT" \
  '.hotspots[] | select(.file=="src/Churn.ts") | (.pr_numbers | index(838)) == null'
check_jq "14d: a file touched only on the feature branch is not counted" "$OUT" \
  '.hotspots | map(.file) | index("src/Branch.ts") == null'
check_jq "14e: the scanned ref is reported" "$OUT" \
  '.scan_ref == "main" and .scan_ref_source == "candidate"'
check_eq "14f: no issue number from the branch leaks into the output" "" \
  "$(printf '%s' "$OUT" | grep -o '838' | head -1)"

# A detached HEAD resolves the same ref — resolution never reads HEAD.
git -C "$R14" checkout -q --detach
run_in "$R14" --since "$WINDOW_START" --json
check_jq "14g: a detached HEAD still scans the default branch" "$OUT" \
  '.hotspots[] | select(.file=="src/Churn.ts") | .pr_numbers == [900,901,902]'
git -C "$R14" checkout -q feature

# =============================================================================
# Scenario 15 — origin/main wins over a local branch that has drifted
# =============================================================================
R15=$(new_repo_on r15 main)
commit_touch "$R15" "2026-02-01T00:00:00" "a (#910)" src/Api.ts
commit_touch "$R15" "2026-02-02T00:00:00" "b (#911)" src/Api.ts
commit_touch "$R15" "2026-02-03T00:00:00" "c (#912)" src/Api.ts
add_origin "$R15" origin15.git main
# Local-only work sitting on top of the published branch.
commit_touch "$R15" "2026-02-04T00:00:00" "docs(#838): unpushed local work" src/Api.ts src/Local.ts

run_in "$R15" --since "$WINDOW_START" --json
check_jq "15a: origin/HEAD resolves the scan ref" "$OUT" \
  '.scan_ref == "origin/main" and .scan_ref_source == "origin-head"'
check_jq "15b: unpushed local commits are not counted" "$OUT" \
  '.hotspots[] | select(.file=="src/Api.ts") | .pr_numbers == [910,911,912]'
check_jq "15c: a file touched only by unpushed work is absent" "$OUT" \
  '.hotspots | map(.file) | index("src/Local.ts") == null'

run_in "$R15" --since "$WINDOW_START" --fetch --json
check_eq "15d: --fetch against a reachable origin still succeeds" "0" "$RC"
check_jq "15e: --fetch is a no-op when the remote-tracking ref is current" "$OUT" \
  '.hotspots[] | select(.file=="src/Api.ts") | .pr_numbers == [910,911,912]'

# Someone else lands a PR: origin moves, this checkout's origin/main does not.
R15B="$TMP/r15b"
git clone -q "$TMP/origin15.git" "$R15B"
git -C "$R15B" config user.email "test@example.com"
git -C "$R15B" config user.name "Test"
commit_touch "$R15B" "2026-02-05T00:00:00" "d (#913)" src/Api.ts
git -C "$R15B" push -q origin main

run_in "$R15" --since "$WINDOW_START" --json
check_jq "15g: without --fetch the stale remote-tracking ref is scanned as-is" "$OUT" \
  '.hotspots[] | select(.file=="src/Api.ts") | (.pr_numbers | index(913)) == null'

run_in "$R15" --since "$WINDOW_START" --fetch --json
check_jq "15h: --fetch picks up a PR merged since the last fetch" "$OUT" \
  '.hotspots[] | select(.file=="src/Api.ts") | .pr_numbers == [910,911,912,913]'

# --fetch runs BEFORE --ref is validated, so an explicit ref sees fresh objects.
run_in "$R15" --since "$WINDOW_START" --ref origin/main --fetch --json
check_jq "15i: --fetch refreshes before an explicit --ref is resolved" "$OUT" \
  '.scan_ref_source == "explicit" and (.hotspots[] | select(.file=="src/Api.ts") | .pr_numbers == [910,911,912,913])'

# No origin at all: --fetch degrades to a warning, never a failure.
run_in "$R1" --since "$WINDOW_START" --fetch --json
check_eq "15j: --fetch with no origin remote is non-fatal" "0" "$RC"

# =============================================================================
# Scenario 16 — a default branch that is not named `main`
# =============================================================================
R16=$(new_repo_on r16 trunk)
commit_touch "$R16" "2026-02-01T00:00:00" "a (#920)" src/Trunk.ts
commit_touch "$R16" "2026-02-02T00:00:00" "b (#921)" src/Trunk.ts
commit_touch "$R16" "2026-02-03T00:00:00" "c (#922)" src/Trunk.ts
add_origin "$R16" origin16.git trunk
# A stray local `main` must NOT outrank the remote's real default branch.
git -C "$R16" checkout -q -b main
commit_touch "$R16" "2026-02-04T00:00:00" "x (#930)" src/Stray.ts
commit_touch "$R16" "2026-02-05T00:00:00" "y (#931)" src/Stray.ts
commit_touch "$R16" "2026-02-06T00:00:00" "z (#932)" src/Stray.ts
git -C "$R16" checkout -q trunk

run_in "$R16" --since "$WINDOW_START" --json
check_jq '16a: origin/HEAD names the real default branch, not main' "$OUT" \
  '.scan_ref == "origin/trunk" and .scan_ref_source == "origin-head"'
check_jq "16b: the default branch's churn is reported" "$OUT" \
  '.hotspots | map(.file) | index("src/Trunk.ts") != null'
check_jq '16c: a stray local main contributes nothing' "$OUT" \
  '.hotspots | map(.file) | index("src/Stray.ts") == null'

# =============================================================================
# Scenario 17 — --ref overrides resolution and never degrades silently
# =============================================================================
run_in "$R14" --since "$WINDOW_START" --ref main --json
check_jq "17a: an explicit --ref is reported as such" "$OUT" \
  '.scan_ref == "main" and .scan_ref_source == "explicit"'

run_in "$R14" --since "$WINDOW_START" --ref feature --json
check_eq "17b: --ref feature scans the branch, which is below threshold" "1" "$RC"

(cd "$R14" && bash "$SCRIPT" --since "$WINDOW_START" --ref no-such-ref --json >/dev/null 2>&1)
check_eq "17c: an unresolvable --ref exits 3 instead of scanning something else" "3" "$?"

(cd "$R14" && bash "$SCRIPT" --since "$WINDOW_START" --ref main --source gh --json >/dev/null 2>&1)
check_eq "17d: --ref on the gh path is a usage error" "2" "$?"

# =============================================================================
# Scenario 18 — HEAD fallback: loud, reported, and extraction still guarded
# =============================================================================
# No origin and no main/master branch, so nothing resolves and the scan degrades
# to HEAD. Every commit carries ONLY a leading (#N) issue prefix, which must
# never be read as a PR number.
R18=$(new_repo_on r18 wip-local)
commit_touch "$R18" "2026-02-01T00:00:00" "docs(#838): summary" src/Guard.ts
commit_touch "$R18" "2026-02-02T00:00:00" "docs(#838): more summary" src/Guard.ts
commit_touch "$R18" "2026-02-03T00:00:00" "fix(#839): another" src/Guard.ts

# --source git pins the path: with no PR-marked commit left, `auto` would
# (correctly) fall through to the gh API instead — see 18e.
run_in "$R18" --since "$WINDOW_START" --source git --json
check_eq "18a: leading-only (#N) markers produce no hotspot" "1" "$RC"
check_jq "18b: the HEAD fallback is reported, never silent" "$OUT" \
  '.scan_ref == "HEAD" and .scan_ref_source == "head-fallback"'

# A history the stricter extraction empties out is indistinguishable from a
# merge-commit repo, so `auto` reaches for real merged data over the API rather
# than reporting a confidently wrong empty answer.
run_in "$R18" --since "$WINDOW_START" --json
check_jq "18e: auto falls through to gh when no trailing marker survives" "$OUT" '.source == "gh"'
check_eq "18c: the issue number never appears anywhere in the output" "" \
  "$(printf '%s' "$OUT" | grep -o '838' | head -1)"

# ...but an explicit --ref cannot ride that fallback: the gh path measures the
# whole repo, so honouring the ref is impossible and quietly scanning something
# else is the exact failure #861 exists to prevent. --source git remains the
# escape hatch that scans the ref as-is.
(cd "$R18" && bash "$SCRIPT" --since "$WINDOW_START" --ref wip-local --json >/dev/null 2>&1)
check_eq "18h: an explicit --ref refuses the gh fallback rather than scanning repo-wide" "3" "$?"
run_in "$R18" --since "$WINDOW_START" --ref wip-local --source git --json
check_eq "18i: --source git still scans the pinned ref as-is (clean, not an error)" "1" "$RC"

# The fallback still WORKS for a properly squashed history.
commit_touch "$R18" "2026-02-04T00:00:00" "one (#940)" src/Ok.ts
commit_touch "$R18" "2026-02-05T00:00:00" "two (#941)" src/Ok.ts
commit_touch "$R18" "2026-02-06T00:00:00" "three (#942)" src/Ok.ts
run_in "$R18" --since "$WINDOW_START" --source git --json
check_jq "18d: the HEAD fallback still detects real squash-merged churn" "$OUT" \
  '.hotspots[] | select(.file=="src/Ok.ts") | .pr_numbers == [940,941,942]'

# Mixed history — trailing-marker commits alongside issue-only ones. One valid
# marker is enough to keep `auto` on the git path; the issue-only commits are
# simply ignored rather than dragging the whole run over to the API.
run_in "$R18" --since "$WINDOW_START" --json
check_jq "18f: auto stays on the git path once any trailing marker exists" "$OUT" '.source == "git"'
check_jq "18g: issue-only commits in a mixed history contribute nothing" "$OUT" \
  '.hotspots | map(.file) | index("src/Guard.ts") == null'

# =============================================================================
# Scenario 19 — deleted files are dropped (issue #1118 regression)
#
# A path that no longer exists at the scanned ref must not appear as a hotspot
# even when its git history carries enough PR-marked commits to cross the
# threshold. The detector's false-positive gap: `git log --name-only` returns
# paths from deletion commits too, so a file deleted after 3 PR touches would
# score 3 and get reported — but it is not a refactor candidate.
#
# Revert-verified: this scenario FAILS against the unfixed script (which has no
# existence check) and PASSES after the fix.
# =============================================================================
R19=$(new_repo_on r19 main)

# Touch src/Gone.ts across 3 squash-style commits (distinct PR numbers), then
# delete it. The git path will see 3 PR touches, but the file will be absent
# from the scanned ref at the time the detector runs.
commit_touch "$R19" "2026-02-01T00:00:00" "feat(#100): add gone (#951)" src/Gone.ts src/Present.ts
commit_touch "$R19" "2026-02-02T00:00:00" "fix(#101): update gone (#952)" src/Gone.ts src/Present.ts
commit_touch "$R19" "2026-02-03T00:00:00" "chore(#102): tweak gone (#953)" src/Gone.ts src/Present.ts
# Delete the file — this commit is also PR-attributed and also "touches" the path
git -C "$R19" rm -q src/Gone.ts
GIT_AUTHOR_DATE="2026-02-04T00:00:00" GIT_COMMITTER_DATE="2026-02-04T00:00:00" \
  git -C "$R19" commit -q -m "feat(#103): cut /open-code-review skill (#954)"
# src/Present.ts remains across enough commits to be a valid hotspot

printf '[]\n' > "$TMP/issue_list.json"
run_in "$R19" --since "$WINDOW_START" --json
check_eq "19a: exit 0 (surviving file is still a hotspot)" "0" "$RC"
check_jq "19b: deleted file is absent from hotspots" "$OUT" \
  '.hotspots | map(.file) | index("src/Gone.ts") == null'
check_jq "19c: still-present file is reported normally" "$OUT" \
  '.hotspots | map(.file) | index("src/Present.ts") != null'
check_jq "19d: missing_count is incremented for the dropped file" "$OUT" \
  '.missing_count > 0'
check_jq "19e: missing_count is a top-level field on all exit paths" "$OUT" \
  'has("missing_count")'

# =============================================================================
# Scenario 20 — a file's own creation commit does not score (issue #1547 AC 1)
#
# 7 of one triage round's 14 flagged files were created inside their own scan
# window, so each mechanically started at score 1-2 and reached the reporting
# threshold on one sweep plus one real touch.
#
# Every assertion below is paired with a NEGATIVE CONTROL (`--include-creation`)
# reproducing the pre-fix behaviour on the same history, so a rule that silently
# stopped running could not pass this scenario.
# =============================================================================
printf '[]\n' > "$TMP/issue_list.json"
R20=$(new_repo_on r20 main)
# src/Old.tsx is born OUTSIDE PR attribution; the other two are born in-window.
commit_touch  "$R20" "2026-02-01T00:00:00" "seed the pre-existing file" src/Old.tsx
commit_create "$R20" "2026-02-02T00:00:00" "feat(#10): add both (#1001)" src/Born.tsx src/BornBusy.tsx
commit_touch  "$R20" "2026-02-03T00:00:00" "fix(#11): edit (#1002)" src/Born.tsx src/BornBusy.tsx src/Old.tsx
commit_touch  "$R20" "2026-02-04T00:00:00" "fix(#12): edit (#1003)" src/Born.tsx src/BornBusy.tsx src/Old.tsx
commit_touch  "$R20" "2026-02-05T00:00:00" "fix(#13): edit (#1004)" src/BornBusy.tsx src/Old.tsx

run_in "$R20" --since "$WINDOW_START" --json
check_jq "20a: a file whose 3rd touch was its own creation drops below threshold" "$OUT" \
  '.hotspots | map(.file) | index("src/Born.tsx") == null'
check_jq "20b: the creation PR is absent from a file that still qualifies" "$OUT" \
  '.hotspots[] | select(.file=="src/BornBusy.tsx") | .pr_numbers == [1002,1003,1004] and .pr_count == 3 and .score == 3'
check_jq "20c: creation_skipped_count reports the dropped touches" "$OUT" \
  '.creation_skipped_count == 2'
check_jq "20d: an excluded creation is still LABELLED, not just spent" "$OUT" \
  '.hotspots[] | select(.file=="src/BornBusy.tsx") | .created_in_window == true and .creation_pr == 1001'
check_jq "20e: a file born outside the window is not labelled as created" "$OUT" \
  '.hotspots[] | select(.file=="src/Old.tsx") | .created_in_window == false and .creation_pr == null'
check_jq "20f: a pre-existing file keeps every one of its PRs" "$OUT" \
  '.hotspots[] | select(.file=="src/Old.tsx") | .pr_numbers == [1002,1003,1004]'
check_jq "20g: the filter settings are reported in the envelope" "$OUT" \
  '.sweep_threshold == 20 and .include_creation == false'

# NEGATIVE CONTROL — the same history scores the creation commit again under
# --include-creation, which is exactly the pre-fix result. Without this, a rule
# that never fired would pass 20a by accident.
run_in "$R20" --since "$WINDOW_START" --include-creation --json
check_jq "20h: NEGATIVE CONTROL — --include-creation restores the pre-fix hotspot" "$OUT" \
  '.hotspots[] | select(.file=="src/Born.tsx") | .pr_numbers == [1001,1002,1003] and .score == 3'
check_jq "20i: NEGATIVE CONTROL — nothing is counted as a skipped creation" "$OUT" \
  '.creation_skipped_count == 0 and .include_creation == true'
check_jq "20j: the creation LABEL is independent of whether the touch scored" "$OUT" \
  '.hotspots[] | select(.file=="src/BornBusy.tsx") | .created_in_window == true and .creation_pr == 1001'

# The TSV contract is unchanged — six columns, no new fields leaking in.
run_in "$R20" --since "$WINDOW_START"
check_eq "20k: TSV still carries exactly the six documented columns" "6" \
  "$(printf '%s' "$OUT" | head -1 | awk -F'\t' '{print NF}')"

# =============================================================================
# Scenario 21 — repo-wide mechanical sweeps score 0 (issue #1547 AC 2)
#
# The measured shape from Issue #1341: a creation, two 39-file rename sweeps
# that touched one hardcoded line, and two real edits. Pre-fix that read as
# score 5; only two of the five touches were about this file at all.
# =============================================================================
sweep_paths() {  # $1 count, $2 prefix -> space-separated paths (word-split at the call site)
  local n="$1" prefix="$2" i=1 out=""
  while [ "$i" -le "$n" ]; do out="$out ${prefix}${i}.ts"; i=$((i + 1)); done
  printf '%s' "$out"
}

R21=$(new_repo_on r21 main)
commit_create "$R21" "2026-02-01T00:00:00" "feat(#20): create the suite (#1201)" src/Roster.ts
commit_touch  "$R21" "2026-02-02T00:00:00" "chore(#21): roster line (#1202)" src/Roster.ts
# Both sweeps touch the SAME 39 paths, as the real rename sweeps did.
commit_touch  "$R21" "2026-02-03T00:00:00" "refactor(#22): rename sweep (#1203)" \
  src/Roster.ts $(sweep_paths 38 src/sweep_a)
commit_touch  "$R21" "2026-02-04T00:00:00" "refactor(#23): rename sweep (#1204)" \
  src/Roster.ts $(sweep_paths 38 src/sweep_a)
commit_touch  "$R21" "2026-02-05T00:00:00" "fix(#24): delete the static list (#1205)" src/Roster.ts

run_in "$R21" --since "$WINDOW_START" --json
check_eq "21a: creation + two sweeps + two real edits no longer crosses threshold 3" "1" "$RC"
check_jq "21b: sweep commits are counted, not hidden" "$OUT" \
  '.sweep_commit_count == 2 and .sweep_skipped_count == 78'
check_jq "21c: the envelope survives the clean exit path with the new fields" "$OUT" \
  'has("sweep_threshold") and has("include_creation") and has("creation_skipped_count")
   and has("sweep_commit_count") and has("sweep_skipped_count")'

run_in "$R21" --since "$WINDOW_START" --threshold 2 --json
check_jq "21d: exactly the two non-mechanical PRs survive" "$OUT" \
  '.hotspots[] | select(.file=="src/Roster.ts") | .pr_numbers == [1202,1205] and .pr_count == 2 and .score == 2'

# NEGATIVE CONTROL 1 — both rules off reproduces the pre-fix score of 5 on the
# identical history.
run_in "$R21" --since "$WINDOW_START" --sweep-threshold 0 --include-creation --json
check_jq "21e: NEGATIVE CONTROL — both rules off restores the pre-fix score of 5" "$OUT" \
  '.hotspots[] | select(.file=="src/Roster.ts") | .pr_numbers == [1201,1202,1203,1204,1205] and .score == 5'
check_jq "21f: NEGATIVE CONTROL — no commit is classified as a sweep at threshold 0" "$OUT" \
  '.sweep_commit_count == 0 and .sweep_skipped_count == 0 and .sweep_threshold == 0'

# NEGATIVE CONTROL 2 — the SAME 39-file commits count again once the threshold
# is above them, so the rule keys on the file count and not on anything
# incidental to these fixtures. Creation stays excluded, isolating the rules.
run_in "$R21" --since "$WINDOW_START" --sweep-threshold 40 --json
check_jq "21g: NEGATIVE CONTROL — the same commits count when below the threshold" "$OUT" \
  '.hotspots[] | select(.file=="src/Roster.ts") | .pr_numbers == [1202,1203,1204,1205] and .score == 4'

# The two rules are independent: sweeps off, creation still excluded.
run_in "$R21" --since "$WINDOW_START" --sweep-threshold 0 --json
check_jq "21h: the two rules are independent of one another" "$OUT" \
  '.hotspots[] | select(.file=="src/Roster.ts") | .pr_numbers == [1202,1203,1204,1205]'

# The >= boundary, measured from both sides on one history.
R21B=$(new_repo_on r21b main)
commit_touch "$R21B" "2026-02-01T00:00:00" "seed" src/Edge.ts
commit_touch "$R21B" "2026-02-02T00:00:00" "sweep of exactly 20 (#1301)" \
  src/Edge.ts $(sweep_paths 19 src/twenty_)
commit_touch "$R21B" "2026-02-03T00:00:00" "sweep of exactly 19 (#1302)" \
  src/Edge.ts $(sweep_paths 18 src/nineteen_)
commit_touch "$R21B" "2026-02-04T00:00:00" "ordinary edit (#1303)" src/Edge.ts

run_in "$R21B" --since "$WINDOW_START" --threshold 2 --json
check_jq "21i: 20 files is a sweep and 19 is not — the >= boundary from both sides" "$OUT" \
  '.hotspots[] | select(.file=="src/Edge.ts") | .pr_numbers == [1302,1303]'
check_jq "21j: exactly one commit was classified as a sweep" "$OUT" \
  '.sweep_commit_count == 1 and .sweep_skipped_count == 20'

# Sweep size is the commit's RAW path count, taken before the exclusion list —
# a 20-file sweep stays a sweep when one of its paths is an excluded lockfile.
R21C=$(new_repo_on r21c main)
commit_touch "$R21C" "2026-02-01T00:00:00" "seed" src/Raw.ts
commit_touch "$R21C" "2026-02-02T00:00:00" "sweep with a lockfile (#1311)" \
  src/Raw.ts package-lock.json $(sweep_paths 18 src/raw_)
commit_touch "$R21C" "2026-02-03T00:00:00" "ordinary (#1312)" src/Raw.ts
commit_touch "$R21C" "2026-02-04T00:00:00" "ordinary (#1313)" src/Raw.ts

run_in "$R21C" --since "$WINDOW_START" --threshold 2 --json
# 20 raw paths, only 19 of which survive the exclusion list — the commit is
# still a sweep, and the excluded lockfile is counted as excluded rather than
# swept, so the two filters never double-count the same path.
check_jq "21k: sweep size counts raw paths, before the exclusion list" "$OUT" \
  '.sweep_commit_count == 1 and .sweep_skipped_count == 19 and .excluded_count == 1
   and (.hotspots[] | select(.file=="src/Raw.ts") | .pr_numbers == [1312,1313])'

(cd "$R21" && bash "$SCRIPT" --sweep-threshold abc >/dev/null 2>&1)
check_eq "21l: a non-numeric --sweep-threshold exits 2" "2" "$?"

# =============================================================================
# Scenario 22 — both rules apply on the gh enumeration path
#
# The gh path has no per-commit granularity, so the sweep unit is the PR's whole
# file list, and creation comes from the API's own `"status": "added"`.
# =============================================================================
R22=$(new_repo_on r22 main)
# The gh path checks the working tree for existence, so the paths must be on
# disk. An unmarked commit keeps the git-path attribution tests unaffected.
commit_touch "$R22" "2026-02-01T00:00:00" "add stub fixture files" \
  src/GhBorn.ts $(sweep_paths 19 src/ghsweep_)

cat > "$TMP/pr_list.json" <<'EOF'
[{"number":1401,"mergedAt":"2026-02-01T00:00:00Z"},
 {"number":1402,"mergedAt":"2026-02-02T00:00:00Z"},
 {"number":1403,"mergedAt":"2026-02-03T00:00:00Z"}]
EOF
gh_files 1401 added    src/GhBorn.ts
gh_files 1402 modified src/GhBorn.ts
gh_files 1403 modified src/GhBorn.ts

printf '[]\n' > "$TMP/issue_list.json"
run_in "$R22" --since "$WINDOW_START" --source gh --threshold 2 --json
check_jq "22a: an \"added\" file on the gh path is not scored as churn" "$OUT" \
  '.hotspots[] | select(.file=="src/GhBorn.ts") | (.pr_numbers | index(1401)) == null'
check_jq "22b: the gh path reports the skipped creation and labels it" "$OUT" \
  '.creation_skipped_count == 1
   and (.hotspots[] | select(.file=="src/GhBorn.ts")
        | .pr_numbers == [1402,1403] and .created_in_window == true and .creation_pr == 1401)'

# NEGATIVE CONTROL — the same fixtures score the creation under --include-creation.
run_in "$R22" --since "$WINDOW_START" --source gh --threshold 2 --include-creation --json
check_jq "22c: NEGATIVE CONTROL — --include-creation restores the gh creation touch" "$OUT" \
  '.hotspots[] | select(.file=="src/GhBorn.ts") | .pr_numbers == [1401,1402,1403]'

# A 20-file PR is a sweep on the gh path too.
SWEEP_ARGS=(modified src/GhBorn.ts)
i=1
while [ "$i" -le 19 ]; do
  SWEEP_ARGS[${#SWEEP_ARGS[@]}]=modified
  SWEEP_ARGS[${#SWEEP_ARGS[@]}]="src/ghsweep_$i.ts"
  i=$((i + 1))
done
gh_files 1403 "${SWEEP_ARGS[@]}"
run_in "$R22" --since "$WINDOW_START" --source gh --threshold 2 --json
check_eq "22d: a 20-file PR is a sweep, dropping the file below threshold 2" "1" "$RC"
check_jq "22e: the sweep PR is counted on the gh path" "$OUT" \
  '.sweep_commit_count == 1 and .sweep_skipped_count == 20'

# Scenario 11's fixtures carry no status key at all — that payload is still
# enumerated rather than silently dropped (verified by 11a-11i above).
gh_files 1403 modified src/GhBorn.ts

# =============================================================================
# Scenario 23 — a file with recorded conflict cost is still flagged
#
# Issue #1547's AC requires the tuned detector to keep flagging anything with
# conflict_rounds > 0. No file in the live 2026-08-15 window has any, so the
# path is pinned here instead of resting on a vacuous live check.
# =============================================================================
cat > "$HOME/.claude/session-state.json" <<'EOF'
{"schema_version":1,"repos":{"testowner/testrepo":{"prs":{
  "1502":{"babysit":{"conflict_streak":2}}
}}}}
EOF
R23=$(new_repo_on r23 main)
commit_create "$R23" "2026-02-01T00:00:00" "feat(#30): create (#1501)" src/Costly.ts
commit_touch  "$R23" "2026-02-02T00:00:00" "fix(#31): conflicted work (#1502)" src/Costly.ts
commit_touch  "$R23" "2026-02-03T00:00:00" "sweep (#1503)" src/Costly.ts $(sweep_paths 25 src/c23_)
commit_touch  "$R23" "2026-02-04T00:00:00" "fix(#32): real edit (#1504)" src/Costly.ts

printf '[]\n' > "$TMP/issue_list.json"
run_in "$R23" --since "$WINDOW_START" --repo testowner/testrepo --json
check_eq "23a: a file with conflict cost is still reported after both filters" "0" "$RC"
check_jq "23b: the creation and the sweep are gone, the conflict weight remains" "$OUT" \
  '.hotspots[] | select(.file=="src/Costly.ts")
   | .pr_numbers == [1502,1504] and .pr_count == 2
     and .conflict_rounds == 2 and .conflict_prs == [1502] and .score == 6'
check_jq "23c: the score formula the consumer asserts still holds exactly" "$OUT" \
  '. as $d | all(.hotspots[]; .score == (.pr_count + ($d.conflict_weight * .conflict_rounds))
                              and (.score | floor) == .score
                              and (.pr_numbers | length) == .pr_count)'
rm -f "$HOME/.claude/session-state.json"

# =============================================================================
# Scenario 24 — a rename destination is a touch, not a creation, whatever the
# ambient `diff.renames` setting says
#
# `--name-status` reports a rename as `R100 old new` only while rename
# detection is on. With `diff.renames = false` the same commit reports
# `D old` + `A new`, so the destination would be dropped as a CREATION — a
# result that varied with the caller's git config and regressed the
# `--name-only` behaviour, which always printed the destination as a touch.
# The detector pins `-M`, so both configs agree.
# =============================================================================
printf '[]\n' > "$TMP/issue_list.json"
for renames in false true; do
  R24=$(new_repo_on "r24_$renames" main)
  git -C "$R24" config diff.renames "$renames"
  commit_touch "$R24" "2026-02-01T00:00:00" "seed" src/Before.ts
  git -C "$R24" mv src/Before.ts src/After.ts
  GIT_AUTHOR_DATE="2026-02-02T00:00:00" GIT_COMMITTER_DATE="2026-02-02T00:00:00" \
    git -C "$R24" commit -q -m "refactor(#40): rename it (#1601)"
  commit_touch "$R24" "2026-02-03T00:00:00" "fix(#41): edit (#1602)" src/After.ts
  commit_touch "$R24" "2026-02-04T00:00:00" "fix(#42): edit (#1603)" src/After.ts

  run_in "$R24" --since "$WINDOW_START" --json
  check_jq "24 (diff.renames=$renames): the rename destination counts as a touch, not a creation" "$OUT" \
    '.hotspots[] | select(.file=="src/After.ts")
     | .pr_numbers == [1601,1602,1603] and .created_in_window == false'
done

# =============================================================================
# Scenario 25 — a copy destination is a creation on the gh path too
#
# The git path reads `C` as a birth (is_creation_status), so a gh path that
# only honoured `"added"` would SCORE a copied file the git path DROPS, and the
# two backends would disagree about identical history. GitHub does not run copy
# detection today, so `"copied"` is unobserved in practice — but it is a
# documented value of its file schema, and the parity must not depend on that.
# Found in review of PR #1550.
# =============================================================================
printf '[]\n' > "$TMP/issue_list.json"
R25=$(new_repo_on r25 main)
# The gh path checks the working tree for existence, so the path must be on
# disk. An unmarked commit keeps the git-path attribution tests unaffected.
commit_touch "$R25" "2026-02-01T00:00:00" "add stub fixture files" src/Copied.ts

cat > "$TMP/pr_list.json" <<'EOF'
[{"number":1701,"mergedAt":"2026-02-01T00:00:00Z"},
 {"number":1702,"mergedAt":"2026-02-02T00:00:00Z"},
 {"number":1703,"mergedAt":"2026-02-03T00:00:00Z"}]
EOF
gh_files 1701 copied   src/Copied.ts
gh_files 1702 modified src/Copied.ts
gh_files 1703 modified src/Copied.ts

run_in "$R25" --since "$WINDOW_START" --source gh --threshold 2 --json
check_jq "25a: a \"copied\" birth is not scored as churn on the gh path" "$OUT" \
  '.hotspots[] | select(.file=="src/Copied.ts") | (.pr_numbers | index(1701)) == null'
check_jq "25b: the copied birth is reported and labelled like an \"added\" one" "$OUT" \
  '.creation_skipped_count == 1
   and (.hotspots[] | select(.file=="src/Copied.ts")
        | .pr_numbers == [1702,1703] and .created_in_window == true
          and .creation_pr == 1701)'

# NEGATIVE CONTROL — without it, 25a/25b could pass on a fixture that never
# reached the creation branch at all. --include-creation must restore the touch.
run_in "$R25" --since "$WINDOW_START" --source gh --threshold 2 --include-creation --json
check_jq "25c: NEGATIVE CONTROL — --include-creation restores the copied touch" "$OUT" \
  '.hotspots[] | select(.file=="src/Copied.ts") | .pr_numbers == [1701,1702,1703]'

# A "renamed" destination is NOT a creation — the same guard must not overreach.
gh_files 1701 renamed src/Copied.ts
run_in "$R25" --since "$WINDOW_START" --source gh --threshold 2 --json
check_jq "25d: a \"renamed\" destination is still a touch, not a creation" "$OUT" \
  '.creation_skipped_count == 0
   and (.hotspots[] | select(.file=="src/Copied.ts")
        | .pr_numbers == [1701,1702,1703] and .created_in_window == false)'

# =============================================================================
# Scenario 26 — a filename with an EMBEDDED NEWLINE is ONE file on both backends
# (issue #1554)
#
# A path may carry any byte but NUL and `/`, a newline included. The gh backend
# counted newline-delimited LINES, so a 2-file PR whose one filename embedded a
# newline counted 3 and drove the --sweep-threshold classification off the wrong
# number. The git backend did not miscount — git C-quotes such a path onto a
# single line — but it then reported the ESCAPED path, which failed the
# existence check and vanished into missing_count. So neither backend told the
# truth and the two disagreed about identical history; both now enumerate
# NUL-delimited, and the assertions below pin them to the SAME answer.
#
# THE PRE-FIX CONTROL IS HERMETIC ON PURPOSE. Running `origin/main`'s copy of the
# detector is the obvious reproduction, but CI checks out shallow (no
# `fetch-depth: 0` in .github/workflows/hook-scripts.yml), so that control would
# SKIP in exactly the environment it exists to protect — a guard that passes by
# not running. Instead: 26i applies the literal pre-fix counting expression to
# the literal pre-fix byte stream, and 26g/26h run the shipped detector twice at
# ONE threshold over payloads differing only in whether the third record is a
# real file or a newline artifact.
# =============================================================================
printf '[]\n' > "$TMP/issue_list.json"
NL_PATH=$(printf 'src/two\nlines.ts')
TAB_PATH=$(printf 'src/tab\there.ts')
# jq string literals cannot carry a raw newline, so the assertions below compare
# against the JSON-escaped form jq itself produces for these paths.
NL_JSON=$(printf '%s' "$NL_PATH" | jq -Rs '.')
TAB_JSON=$(printf '%s' "$TAB_PATH" | jq -Rs '.')

R26=$(new_repo_on r26 main)
# src/Second.ts and src/Third.ts exist only so the gh-path existence check can
# find them in 26h; no PR-marked commit ever touches them, so they stay out of
# the git-path parity comparison.
commit_touch "$R26" "2026-02-01T00:00:00" "seed the fixture paths" \
  "$NL_PATH" src/Plain.ts src/Second.ts src/Third.ts
commit_touch "$R26" "2026-02-02T00:00:00" "first (#1801)"  "$NL_PATH" src/Plain.ts
commit_touch "$R26" "2026-02-03T00:00:00" "second (#1802)" "$NL_PATH" src/Plain.ts

run_in "$R26" --since "$WINDOW_START" --threshold 2 --sweep-threshold 3 --json
check_eq "26a: git — exit 0 with an embedded-newline path in history" "0" "$RC"
# THE git-side regression pin. Pre-fix this path arrived C-quoted as
# "src/two\nlines.ts", failed `git cat-file -e` under that literal name, and was
# dropped as missing — so the file was invisible rather than miscounted.
check_jq "26b: git — the embedded-newline path is reported VERBATIM, not escaped" "$OUT" \
  ".hotspots | map(.file) | index($NL_JSON) != null"
check_jq "26c: git — it is ONE file carrying both PRs" "$OUT" \
  ".hotspots[] | select(.file == $NL_JSON) | .pr_count == 2 and .pr_numbers == [1801,1802]"
check_jq "26d: git — 2 paths is not a sweep at --sweep-threshold 3" "$OUT" \
  '.sweep_commit_count == 0 and .missing_count == 0'

# NEGATIVE CONTROL — the sweep rule is live on this history: at a threshold of 2
# the same two commits DO sweep, so 26d is a measurement and not an inert pass.
run_in "$R26" --since "$WINDOW_START" --threshold 2 --sweep-threshold 2 --json
check_jq "26e: NEGATIVE CONTROL — git — the same commits sweep at --sweep-threshold 2" "$OUT" \
  '.sweep_commit_count == 2 and (.hotspots | length) == 0'

# A TAB inside a filename is a hazard `-z` INTRODUCES: git used to quote such a
# path, and the old parser took the last tab-separated field as the path, so a
# verbatim tab would have truncated it to "here.ts".
R26B=$(new_repo_on r26b main)
commit_touch "$R26B" "2026-02-01T00:00:00" "seed" "$TAB_PATH"
commit_touch "$R26B" "2026-02-02T00:00:00" "one (#1811)"   "$TAB_PATH"
commit_touch "$R26B" "2026-02-03T00:00:00" "two (#1812)"   "$TAB_PATH"
commit_touch "$R26B" "2026-02-04T00:00:00" "three (#1813)" "$TAB_PATH"
run_in "$R26B" --since "$WINDOW_START" --json
check_jq "26f: git — a TAB inside a filename survives verbatim, untruncated" "$OUT" \
  ".hotspots[] | select(.file == $TAB_JSON) | .pr_numbers == [1811,1812,1813]"

# ---- the gh backend, same history ------------------------------------------
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":1801,"mergedAt":"2026-02-02T00:00:00Z"},
 {"number":1802,"mergedAt":"2026-02-03T00:00:00Z"}]
EOF
gh_files 1801 modified "$NL_PATH" modified src/Plain.ts
gh_files 1802 modified "$NL_PATH" modified src/Plain.ts

run_in "$R26" --since "$WINDOW_START" --source gh --threshold 2 --sweep-threshold 3 --json
check_eq "26g: gh — exit 0; a 2-file PR is not a sweep at --sweep-threshold 3" "0" "$RC"
check_jq "26h: gh — the embedded-newline filename counts as ONE file, not two" "$OUT" \
  ".sweep_commit_count == 0
   and (.hotspots[] | select(.file == $NL_JSON) | .pr_count == 2 and .pr_numbers == [1801,1802])"

# PARITY — the whole point of the ticket: identical history, identical answer.
GIT_VIEW=$(cd "$R26" && bash "$SCRIPT" --since "$WINDOW_START" --threshold 2 --sweep-threshold 3 --json 2>/dev/null \
  | jq -c '[.hotspots[] | {file, pr_count, pr_numbers}] | sort_by(.file)')
GH_VIEW=$(cd "$R26" && bash "$SCRIPT" --since "$WINDOW_START" --source gh --threshold 2 --sweep-threshold 3 --json 2>/dev/null \
  | jq -c '[.hotspots[] | {file, pr_count, pr_numbers}] | sort_by(.file)')
check_eq "26i: PARITY — git and gh report identical files, counts and PR evidence" "$GIT_VIEW" "$GH_VIEW"
check_jq "26j: PARITY — and that shared answer really contains the newline path" "$GIT_VIEW" \
  "map(.file) | index($NL_JSON) != null"

# NEGATIVE CONTROL — at the SAME --sweep-threshold 3, a payload whose third file
# is REAL does sweep. The only difference from 26h is whether the third record is
# a file or a newline artifact, which is exactly what the pre-fix line count
# could not tell apart.
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":1821,"mergedAt":"2026-02-02T00:00:00Z"},
 {"number":1822,"mergedAt":"2026-02-03T00:00:00Z"}]
EOF
gh_files 1821 modified src/Plain.ts modified src/Second.ts modified src/Third.ts
gh_files 1822 modified src/Plain.ts modified src/Second.ts modified src/Third.ts
run_in "$R26" --since "$WINDOW_START" --source gh --threshold 2 --sweep-threshold 3 --json
check_eq "26k: NEGATIVE CONTROL — gh — a genuine 3-file PR still sweeps at the same threshold" "1" "$RC"
check_jq "26l: NEGATIVE CONTROL — gh — both real 3-file PRs are counted as sweeps" "$OUT" \
  '.sweep_commit_count == 2 and .sweep_skipped_count == 6'

# PRE-FIX CONTROL — the exact stream `gh api --jq '… | join("<TAB>")'` emitted for
# the 26h payload, counted with the exact pre-fix expression. Three lines for two
# files: that number is the bug, and 26h shows the shipped detector now says two.
{ printf 'modified\t%s\n' "$NL_PATH"; printf 'modified\t%s\n' 'src/Plain.ts'; } > "$TMP/prefix_stream.txt"
check_eq "26m: PRE-FIX CONTROL — the newline-delimited stream counts 3 lines for 2 files" \
  "3" "$(sed '/^$/d' "$TMP/prefix_stream.txt" | wc -l | tr -d '[:space:]')"
check_eq "26n: PRE-FIX CONTROL — NUL-terminating the same two records counts 2" \
  "2" "$({ printf 'modified\t%s\000' "$NL_PATH"; printf 'modified\t%s\000' 'src/Plain.ts'; } | tr -dc '\000' | wc -c | tr -d '[:space:]')"

# An EMPTY file payload must leave the NUL reader at zero records rather than
# tripping `set -u` on the loop guard that catches an unterminated final record.
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":1831,"mergedAt":"2026-02-02T00:00:00Z"}]
EOF
gh_files 1831
run_in "$R26" --since "$WINDOW_START" --source gh --threshold 2 --json
check_eq "26o: gh — a PR with an empty file list exits clean, not with an error" "1" "$RC"
check_jq "26p: gh — the empty PR is still counted as scanned, with no touches" "$OUT" \
  '.scanned_pr_count == 1 and (.hotspots | length) == 0 and .sweep_commit_count == 0'

# =============================================================================
echo
echo "churn-hotspots.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
