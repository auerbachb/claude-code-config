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
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  *"repo view"*)      cat "$TMP/repo_view.txt" ;;
  *"issue list"*)     cat "$TMP/issue_list.json" ;;
  *"pr list"*)        cat "$TMP/pr_list.json" ;;
  *"/files"*)
    pr=\$(printf '%s' "\$args" | sed -n 's|.*/pulls/\([0-9][0-9]*\)/files.*|\1|p')
    if [ -f "$TMP/files_\$pr.txt" ]; then cat "$TMP/files_\$pr.txt"; else printf ''; fi
    ;;
  *) echo "gh stub: unhandled args: \$args" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

printf 'testowner/testrepo\n' > "$TMP/repo_view.txt"
printf '[]\n' > "$TMP/issue_list.json"
printf '[]\n' > "$TMP/pr_list.json"

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

commit_touch() {  # $1 repo, $2 date, $3 subject, $4... files
  local repo="$1" date="$2" subject="$3"; shift 3
  local f
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    echo "change $date" >> "$repo/$f"
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
# =============================================================================
printf '[]\n' > "$TMP/issue_list.json"
run_in "$R1" --since "$WINDOW_START" --json
check_jq "7a: no matching issue leaves existing_hotspot_issue null (file path)" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == null'
check_jq "7b: a successful empty lookup is not a failure" "$OUT" '.existing_lookup_failed == false'

cat > "$TMP/issue_list.json" <<'EOF'
[{"number":900,"title":"Refactor hotspot: src/Form.tsx","body":"evidence"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8a: an exact title match populates existing_hotspot_issue (comment path)" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 900'

# Body marker alone is enough, even when the title was edited by a human
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":901,"title":"Split the giant form component","body":"context\n<!-- churn-hotspot: src/Form.tsx -->\n"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "8b: the body marker matches even after a title edit" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == 901'

# Near-miss titles must NOT match — GitHub tokenizes paths, exact match is the guard
cat > "$TMP/issue_list.json" <<'EOF'
[{"number":902,"title":"Refactor hotspot: src/OtherForm.tsx","body":"different file"},
 {"number":903,"title":"Refactor hotspot: src/Form.tsx.bak","body":"different file"}]
EOF
run_in "$R1" --since "$WINDOW_START" --json
check_jq "9a: a sibling-file hotspot issue does not match" "$OUT" \
  '.hotspots[] | select(.file=="src/Form.tsx") | .existing_hotspot_issue == null'

# A capped issue lookup is an INCOMPLETE lookup: a matching issue may sit beyond
# the cap, so absence of a match no longer proves absence of an issue. Callers
# gate filing on existing_lookup_failed, so the cap must set it — reporting only
# `truncated` would let a caller file a duplicate.
python3 - "$TMP/issue_list.json" <<'PY'
import json, sys
# 200 non-matching issues == ISSUE_LOOKUP_CAP, so the lookup is capped out.
json.dump([{"number": 1000 + i, "title": "Refactor hotspot: src/Unrelated%d.ts" % i, "body": ""}
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
printf 'src/Api.ts\nREADME.md\n' > "$TMP/files_801.txt"
printf 'src/Api.ts\n'             > "$TMP/files_802.txt"
printf 'src/Api.ts\n'             > "$TMP/files_803.txt"
printf 'src/Api.ts\n'             > "$TMP/files_804.txt"

R11=$(new_repo r11)
commit_touch "$R11" "2026-02-01T00:00:00" "unmarked local commit" src/Ignored.ts

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
for n in 811 812 813 814; do printf 'src/Edge.ts\n' > "$TMP/files_$n.txt"; done
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
REF_SHA=$(git -C "$R11B" rev-parse HEAD)
cat > "$TMP/pr_list.json" <<'EOF'
[{"number":821,"mergedAt":"2026-03-01T12:00:00Z"},
 {"number":822,"mergedAt":"2026-03-01T20:00:00Z"},
 {"number":823,"mergedAt":"2026-03-04T09:00:00Z"}]
EOF
for n in 821 822 823; do printf 'src/Ref.ts\n' > "$TMP/files_$n.txt"; done
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
echo
echo "churn-hotspots.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
