#!/usr/bin/env bash
# Tests for review-tier.sh — per-repo review tier resolution from pm-config's
# `## Review policy` (issue #1725, part of #1724).
# catalog: tests — Tests for `review-tier.sh` — policy parsing, strictest-wins resolution, fail-closed invalid policies, PR-mode base-branch reads
#
# Offline cases drive --files-from/--labels/--config. PR-mode cases put a fake
# `gh` first on PATH that serves the PR, its files and the base-branch
# pm-config; any call it does not recognise is a hard error, so a code path
# that stops making (or starts making) a call cannot pass silently.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/review-tier.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL — $*" >&2; }

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi
}

POLICY="$TMP_DIR/pm-config.md"
write_policy() {
  { printf '# PM Config\n\n## Role\n\nnothing\n\n## Review policy\n\n'; cat; printf '\n## Notes\n\n| Tier | Gate |\n|---|---|\n| stray | ci-only |\n'; } > "$POLICY"
}

STANDARD_TABLE='| Tier | Gate | Paths | Labels |
|------|------|-------|--------|
| core | full | `src/ledger/**`, migrations/ | tier:core |
| leaf | ci+codeant-one-round | src/adapters/** | tier:leaf |
| docs | ci-only | docs/**, *.md | tier:docs |'

# gate_for <files (newline-separated)> [labels-csv]  — plain output
gate_for() {
  if [[ $# -ge 2 ]]; then
    printf '%s' "$1" | bash "$SUT" --files-from - --config "$POLICY" --labels "$2" 2>/dev/null
  else
    printf '%s' "$1" | bash "$SUT" --files-from - --config "$POLICY" 2>/dev/null
  fi
}
json_for() {
  printf '%s' "$1" | bash "$SUT" --files-from - --config "$POLICY" --json 2>/dev/null
}

# ------------------------------------------------------------ absent -------

printf '# PM Config\n\n## Active work\n\n```ini\nACTIVE_WORK_CAP=6\n```\n' > "$POLICY"
check "no Review policy section → legacy" "legacy" "$(gate_for 'src/a.ts')"
out="$(json_for 'src/a.ts')"
check "absent → policy absent" "absent" "$(jq -r .policy <<<"$out")"
check "absent → tier null" "null" "$(jq -r .tier <<<"$out")"
check "absent → matches []" "[]" "$(jq -c .matches <<<"$out")"

write_policy <<'EOF'
Every PR gets the full gate for now; tiers come later.
EOF
check "prose-only section → legacy" "legacy" "$(gate_for 'src/a.ts')"
err="$(printf 'src/a.ts' | bash "$SUT" --files-from - --config "$POLICY" 2>&1 >/dev/null)"
case "$err" in *"no table"*) ok "prose-only section warns on stderr" ;; *) bad "prose-only section should warn, got [$err]" ;; esac

write_policy <<'EOF'
Example only — not active:

```
| Tier | Gate |
|---|---|
| docs | ci-only |
```

<!--
| Tier | Gate |
|---|---|
| docs | ci-only |
-->
EOF
check "tables inside fences and HTML comments are ignored" "legacy" "$(gate_for 'docs/a.md')"

# An inner ``` must not close a ```` fence: the table inside stays an example,
# and the real table after the fence governs.
write_policy <<'EOF'
````markdown
```
| Tier | Gate |
|---|---|
| default | ci-only |
````

| Tier | Gate |
|---|---|
| default | full |
EOF
check "inner 3-backtick line does not close a 4-backtick fence" "full" "$(gate_for 'docs/a.md')"

write_policy <<'EOF'
~~~
```
| Tier | Gate |
|---|---|
| default | ci-only |
~~~
EOF
check "a backtick line does not close a tilde fence" "legacy" "$(gate_for 'docs/a.md')"

# A backtick run with another backtick after it is an inline code span, not a
# fence opener — the table below it is live.
write_policy <<'EOF'
```full```

```ci-only```

| Tier | Gate | Paths | Labels |
| --- | --- | --- | --- |
| default | full | | |
EOF
check "inline code spans are not fence openers" "full" "$(gate_for 'docs/a.md')"

write_policy <<'EOF'
~~~ info with `backticks`
| Tier | Gate |
|---|---|
| default | ci-only |
~~~
EOF
check "a tilde fence whose info string has backticks still opens" "legacy" "$(gate_for 'docs/a.md')"

# Four spaces of indentation make an indented code block, not a fence: the
# live table after it must not be swallowed by a fence that never opened.
write_policy <<'EOF'
    ```
| Tier | Gate |
|---|---|
| default | full |
EOF
check "a 4-space-indented backtick run is not a fence opener" "full" "$(gate_for 'docs/a.md')"
write_policy <<'EOF'
```
| Tier | Gate |
|---|---|
| default | ci-only |
    ```
```

| Tier | Gate |
|---|---|
| default | full |
EOF
check "a 4-space-indented closer does not close a fence" "full" "$(gate_for 'docs/a.md')"

write_policy <<'EOF'
Example (indented code, not live):

    | Tier | Gate |
    |---|---|
    | default | ci-only |

| Tier | Gate |
|---|---|
| default | full |
EOF
check "an indented code block table is not the live table" "full" "$(gate_for 'docs/a.md')"

write_policy <<'EOF'
| Tier | Gate |
|---|---|
| default | ci-only |

Tier | Gate
--- | ---
core | full
EOF
out="$(json_for 'docs/a.md')"
check "a second table without edge pipes → invalid, full" "invalid/full" "$(jq -r '.policy + "/" + .gate' <<<"$out")"

check "missing --config file → legacy" "legacy" \
  "$(printf 'x' | bash "$SUT" --files-from - --config "$TMP_DIR/nope.md" 2>/dev/null)"
err="$(printf 'x' | bash "$SUT" --files-from - --config "$TMP_DIR/nope.md" 2>&1 >/dev/null)"
case "$err" in *"not found"*) ok "missing --config file warns" ;; *) bad "missing --config should warn, got [$err]" ;; esac

# A config that EXISTS but cannot be read is a read failure, never "absent".
ln -s "$TMP_DIR/no-such-target.md" "$TMP_DIR/dangling.md"
out="$(printf 'x' | bash "$SUT" --files-from - --config "$TMP_DIR/dangling.md" 2>/dev/null)"; rc=$?
check "--config dangling symlink → exit 4" "4" "$rc"
check "--config dangling symlink → nothing on stdout" "" "$out"

mkdir -p "$TMP_DIR/a-directory"
out="$(printf 'x' | bash "$SUT" --files-from - --config "$TMP_DIR/a-directory" 2>/dev/null)"; rc=$?
check "--config pointing at a directory → exit 4" "4" "$rc"
check "--config directory → nothing on stdout" "" "$out"
if [[ "$(id -u)" != "0" ]]; then
  printf '## Review policy\n' > "$TMP_DIR/unreadable.md"; chmod 000 "$TMP_DIR/unreadable.md"
  out="$(printf 'x' | bash "$SUT" --files-from - --config "$TMP_DIR/unreadable.md" 2>/dev/null)"; rc=$?
  chmod 600 "$TMP_DIR/unreadable.md"
  check "unreadable --config → exit 4" "4" "$rc"
  check "unreadable --config → nothing on stdout" "" "$out"
fi

# Offline mode outside any git checkout, with no --config: nowhere to read the
# policy from is a read failure, not "no policy".
mkdir -p "$TMP_DIR/not-a-repo"
out="$(cd "$TMP_DIR/not-a-repo" && printf 'x' | GIT_CEILING_DIRECTORIES="$TMP_DIR" bash "$SUT" --files-from - 2>/dev/null)"; rc=$?
check "offline mode outside a git checkout → exit 4" "4" "$rc"
check "offline mode outside a git checkout → nothing on stdout" "" "$out"

# ------------------------------------------------------ table parsing ------

# A fenced example that contains its own `## Review policy` heading (here
# under ## Notes) must never become the live section.
{ printf '# PM Config\n\n## Notes\n\nExample:\n\n```markdown\n## Review policy\n\n| Tier | Gate |\n|---|---|\n| default | ci-only |\n```\n'; } > "$POLICY"
check "a fenced example heading is not the live section" "legacy" "$(gate_for 'docs/a.md')"
{ printf '# PM Config\n\n## Notes\n\n<!--\n## Review policy\n\n| Tier | Gate |\n|---|---|\n| default | ci-only |\n-->\n'; } > "$POLICY"
check "a commented-out heading is not the live section" "legacy" "$(gate_for 'docs/a.md')"

# Prose that merely contains a pipe before the table is not a table header.
write_policy <<'EOF'
Gates are ci-only | ci+codeant-one-round | full, strictest wins.

| Tier | Gate | Paths |
|---|---|---|
| core | full | src/ledger/** |
| default | ci-only | |
EOF
check "prose containing | before the table is skipped" "ci-only" "$(gate_for 'docs/a.md')"
check "…and the real table still governs core" "full" "$(gate_for 'src/ledger/x.ts')"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| default | ci-only | |

Remember: a | b in prose after the table is fine.
EOF
check "prose containing | after the table is not refused" "ci-only" "$(gate_for 'docs/a.md')"

write_policy <<'EOF'
Gates: ci-only | full
---|---|---

| Tier | Gate |
|---|---|
| default | ci-only |
EOF
check "a delimiter row with a different cell count does not make prose a table" "ci-only" "$(gate_for 'docs/a.md')"

write_policy <<'EOF'
Tier | Gate | Paths
---- | ---- | -----
docs | ci-only | docs/**
core | full | src/ledger/**
EOF
check "GFM table without edge pipes parses" "full" "$(gate_for 'src/ledger/x.ts')"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only | *.md |
core | full | src/ledger/** |
EOF
check "a row missing its leading pipe still parses (core stays full)" "full" "$(gate_for 'src/ledger/README.md')"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only | *.md |

| core | full | src/ledger/** |
EOF
out="$(json_for 'src/ledger/README.md')"
check "rows cut off by a blank line → invalid, full" "invalid/full" "$(jq -r '.policy + "/" + .gate' <<<"$out")"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only | *.md |
<!-- core is below -->
| core | full | src/ledger/** |
EOF
out="$(json_for 'src/ledger/README.md')"
check "rows cut off by a comment line → invalid, full" "invalid/full" "$(jq -r '.policy + "/" + .gate' <<<"$out")"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only | docs/** |
| core | full | **/migrations/** |
| default | ci-only | |
EOF
check "leading **/ also matches at the root" "full" "$(gate_for 'migrations/001.sql')"
check "leading **/ matches nested dirs" "full" "$(gate_for 'db/migrations/001.sql')"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| core | full | src/{ledger,auth}/** |
| default | ci-only | |
EOF
out="$(json_for 'src/ledger/x.ts')"
check "brace glob → invalid, full (never a dead half)" "invalid/full" "$(jq -r '.policy + "/" + .gate' <<<"$out")"

printf '# PM Config\r\n\r\n## Review policy\r\n\r\n| Tier | Gate | Paths |\r\n|---|---|---|\r\n| docs | ci-only | docs/** |\r\n' > "$POLICY"
check "CRLF pm-config parses like LF" "ci-only" "$(gate_for 'docs/a.md')"

printf '# PM Config\n\n## Review Policy\n\n| Tier | Gate |\n|---|---|\n| default | ci-only |\n' > "$POLICY"
out="$(json_for 'docs/a.md')"
check "near-miss heading (other case) → invalid, full" "invalid/full" "$(jq -r '.policy + "/" + .gate' <<<"$out")"

printf '# PM Config\n\n## Review policy\n\n## Notes\n' > "$POLICY"
check "exact heading with an empty body → legacy" "legacy" "$(gate_for 'docs/a.md')"

# ----------------------------------------------------------- present -------

write_policy <<<"$STANDARD_TABLE"
check "docs-only PR → ci-only" "ci-only" "$(gate_for $'docs/a.md\nREADME.md')"
check "leaf-only PR → ci+codeant-one-round" "ci+codeant-one-round" "$(gate_for 'src/adapters/x.ts')"
check "docs + core mix → core wins (full)" "full" "$(gate_for $'docs/a.md\nsrc/ledger/x.ts')"
check "trailing-slash path covers everything under it" "full" "$(gate_for 'migrations/2026/001.sql')"
check "a path with a leading space is not trimmed onto docs/**" "full" "$(gate_for ' docs/a.txt')"
out="$(json_for $'src/ledger/a\tb.ts')"
check "a tab in a path keeps the match summary's columns intact" "src/ledger/a b.ts" \
  "$(jq -r '.matches[] | select(.tier == "core") | .examples[0]' <<<"$out")"
check "unmatched file with no default row → full" "full" "$(gate_for $'docs/a.md\nsrc/other.ts')"
check "a file in a core dir that is also *.md is core (strictest)" "full" "$(gate_for 'src/ledger/README.md')"

out="$(json_for $'docs/a.md\nsrc/ledger/x.ts')"
check "json names the winning tier" "core" "$(jq -r .tier <<<"$out")"
check "json policy present" "present" "$(jq -r .policy <<<"$out")"
check "json lists a path match per tier" "core:path:1,docs:path:1" \
  "$(jq -r '[.matches[] | "\(.tier):\(.via):\(.count)"] | sort | join(",")' <<<"$out")"

out="$(json_for $'docs/a.md\nsrc/other.ts')"
check "implicit default reported as tier 'default'" "default" "$(jq -r .tier <<<"$out")"
check "implicit default carries the full gate" "full" \
  "$(jq -r '.matches[] | select(.via == "default") | .gate' <<<"$out")"

# ------------------------------------------------------------- labels ------

check "label classifies unmatched files" "ci-only" "$(gate_for 'src/other.ts' 'tier:docs')"
check "labels match case-insensitively" "ci-only" "$(gate_for 'src/other.ts' 'Tier:Docs')"
check "label never lowers a path-matched core file" "full" "$(gate_for 'src/ledger/x.ts' 'tier:docs')"
check "a stricter label raises a docs PR" "full" "$(gate_for 'docs/a.md' 'tier:core')"
check "unrelated label → default still applies" "full" "$(gate_for 'src/other.ts' 'bug')"
check "label matches whole names only" "full" "$(gate_for 'src/other.ts' 'docs')"

# ------------------------------------------------------------ default ------

write_policy <<EOF
$STANDARD_TABLE
| default | ci+codeant-one-round | | |
EOF
check "default row classifies unmatched files" "ci+codeant-one-round" "$(gate_for $'docs/a.md\nsrc/other.ts')"
check "PR with no files → default row" "ci+codeant-one-round" "$(gate_for '')"
check "default row never lowers a core file" "full" "$(gate_for $'src/other.ts\nsrc/ledger/x.ts')"

write_policy <<'EOF'
| Gate | Labels | Tier | Owner |
|:----:|--------|------|-------|
| ci-only | | default | someone |
EOF
check "columns matched by header name, unknown columns ignored" "ci-only" "$(gate_for 'anything/at/all.ts')"

# ------------------------------------------------------------ invalid ------

expect_invalid() {
  # expect_invalid <description> <error substring>
  local out err
  out="$(printf 'docs/a.md' | bash "$SUT" --files-from - --config "$POLICY" --json 2>/dev/null)"
  err="$(printf 'docs/a.md' | bash "$SUT" --files-from - --config "$POLICY" 2>&1 >/dev/null)"
  if [[ "$(jq -r '.policy + "/" + .gate' <<<"$out")" == "invalid/full" ]]; then
    ok "$1 → invalid, full gate"
  else
    bad "$1: expected invalid/full, got [$out]"
  fi
  case "$(jq -r .error <<<"$out")" in
    *"$2"*) ok "$1 → error names the cause" ;;
    *) bad "$1: error should mention [$2], got [$(jq -r .error <<<"$out")]" ;;
  esac
  case "$err" in *"invalid"*) ok "$1 → stderr warning" ;; *) bad "$1: no stderr warning" ;; esac
}

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only-ish | docs/** |
EOF
expect_invalid "unknown gate value" "unknown gate"

write_policy <<'EOF'
| Name | Paths |
|---|---|
| docs | docs/** |
EOF
expect_invalid "missing Gate column" "Tier and Gate"

write_policy <<'EOF'
| Tier | Gate | Paths |
| docs | ci-only | docs/** |
EOF
expect_invalid "no header separator row" "separator"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
EOF
expect_invalid "header with no rows" "no tiers"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
| docs | ci-only | docs/** |
| Docs | full | src/** |
EOF
expect_invalid "duplicate tier name (case-insensitive)" "duplicate"

write_policy <<'EOF'
| Tier | Gate | Paths |
|---|---|---|
|  | ci-only | docs/** |
EOF
expect_invalid "empty tier name" "empty Tier"

# --------------------------------------------------------------- usage -----

bash "$SUT" >/dev/null 2>&1; check "no arguments → exit 2" "2" "$?"
bash "$SUT" 12 --files-from - </dev/null >/dev/null 2>&1; check "PR number plus --files-from → exit 2" "2" "$?"
bash "$SUT" 12 --labels x >/dev/null 2>&1; check "--labels in PR mode → exit 2" "2" "$?"
bash "$SUT" abc >/dev/null 2>&1; check "non-numeric PR → exit 2" "2" "$?"
bash "$SUT" --help >/dev/null 2>&1; check "--help → exit 0" "0" "$?"

# ------------------------------------------------------------- PR mode -----

BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Fake gh for review-tier.sh PR mode. Unknown calls are hard errors.
ARGS=" $* "
echo "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "repo view") echo "o/r" ;;
  "pr view")
    [[ "${FAKE_PR_MISSING:-0}" == "1" ]] && { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
    case "$ARGS" in *" --repo o/r "*) ;; *) echo "fake gh: pr view without --repo o/r: $*" >&2; exit 96 ;; esac
    printf '{"baseRefName":"main","labels":%s,"changedFiles":%s}\n' "${FAKE_LABELS:-[]}" "${FAKE_CHANGED-2}" ;;
  "api repos/o/r/pulls/7/files?per_page=100")
    case "$ARGS" in *" --paginate "*) ;; *) echo "fake gh: files call must paginate" >&2; exit 96 ;; esac
    [[ "${FAKE_FILES_FAIL:-0}" == "1" ]] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    # Apply the caller's REAL --jq filter to a files payload, the way gh does,
    # so the listing format the script parses is exercised rather than faked.
    JQ=""; prev=""
    for a in "$@"; do [[ "$prev" == "--jq" ]] && JQ="$a"; prev="$a"; done
    [[ -n "$JQ" ]] || { echo "fake gh: files call without --jq" >&2; exit 96; }
    PAYLOAD="${FAKE_FILES_JSON:-}"
    if [[ -z "$PAYLOAD" ]]; then
      PAYLOAD="$(printf '%s' "${FAKE_FILES:-}" | jq -R -s -c 'split("\n") | map(select(length > 0) | {filename: .})')"
    fi
    jq -r "$JQ" <<<"$PAYLOAD" ;;
  "api --method")
    case "$ARGS" in *" repos/o/r/contents/.claude/pm-config.md "*" ref=main "*) ;; *) echo "fake gh: unexpected contents call: $*" >&2; exit 96 ;; esac
    case "${FAKE_CONTENT_MODE:-ok}" in
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      500) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
    esac
    case "${FAKE_CONTENT_MODE:-ok}" in
      symlink) printf '{"type":"symlink","target":"elsewhere.md","encoding":null}\n'; exit 0 ;;
      nocontent) printf '{"type":"file","encoding":"none","content":""}\n'; exit 0 ;;
    esac
    # The real API wraps base64 at 60 columns with embedded newlines.
    B64="$(base64 < "$FAKE_BASE_CONFIG" | tr -d '\n' | fold -w 60 | awk '{printf "%s\\n", $0}')"
    printf '{"type":"file","encoding":"base64","content":"%s"}\n' "$B64" ;;
  *) echo "fake gh: unrecognised call: $*" >&2; exit 97 ;;
esac
GHEOF
chmod +x "$BIN/gh"
export FAKE_GH_LOG="$TMP_DIR/gh.log"
export FAKE_BASE_CONFIG="$TMP_DIR/base-pm-config.md"

pr_gate() { PATH="$BIN:$PATH" bash "$SUT" 7 "$@" 2>/dev/null; }

write_policy <<<"$STANDARD_TABLE"
cp "$POLICY" "$FAKE_BASE_CONFIG"

check "PR mode reads files + base-branch policy" "ci-only" "$(FAKE_FILES=$'docs/a.md\nREADME.md' FAKE_CHANGED=2 pr_gate)"
out="$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 pr_gate --json)"
check "PR mode source names the base ref" "base:main" "$(jq -r .source <<<"$out")"
check "PR mode labels come from the PR" "full" \
  "$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 FAKE_LABELS='[{"name":"tier:core"}]' pr_gate)"
# A rename out of a core directory classifies the old path too.
check "rename out of core still counts the core path" "full" \
  "$(FAKE_FILES_JSON='[{"filename":"docs/moved.md","previous_filename":"src/ledger/moved.md"}]' FAKE_CHANGED=1 pr_gate)"
# A rename's previous path must not pad the count: 2 changed, 1 listed (a
# docs→docs rename, ci-only on its own) is a truncated listing → full.
check "rename does not mask a truncated listing" "full" \
  "$(FAKE_FILES_JSON='[{"filename":"docs/b.md","previous_filename":"docs/a.md"}]' FAKE_CHANGED=2 pr_gate)"
check "an untruncated docs→docs rename stays ci-only" "ci-only" \
  "$(FAKE_FILES_JSON='[{"filename":"docs/b.md","previous_filename":"docs/a.md"}]' FAKE_CHANGED=1 pr_gate)"
# A path with a newline would split its own record; it can never be
# classified, so the PR fails closed to full rather than dropping the file.
out="$(FAKE_FILES_JSON='[{"filename":"docs/a.md"},{"filename":"src/ledger/x\ny.ts"}]' FAKE_CHANGED=2 pr_gate --json)"
check "a newline in a changed path → full" "full" "$(jq -r .gate <<<"$out")"
check "…reported as unclassifiable" "true" "$(jq -r '[.matches[] | select(.via == "truncated")] | length > 0' <<<"$out")"
check "truncated file listing → full" "full" \
  "$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=3001 pr_gate)"
check "base branch without pm-config.md (404) → legacy" "legacy" \
  "$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 FAKE_CONTENT_MODE=404 pr_gate)"

out="$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 FAKE_CONTENT_MODE=500 pr_gate)"; rc=$?
check "policy read failure → exit 4" "4" "$rc"
check "policy read failure → nothing on stdout" "" "$out"
out="$(FAKE_FILES_FAIL=1 pr_gate)"; rc=$?
check "file listing failure → exit 4" "4" "$rc"
check "file listing failure → nothing on stdout" "" "$out"
out="$(FAKE_PR_MISSING=1 pr_gate)"; rc=$?
check "missing PR → exit 3" "3" "$rc"
check "missing PR → nothing on stdout" "" "$out"

for mode in symlink nocontent; do
  out="$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 FAKE_CONTENT_MODE=$mode pr_gate)"; rc=$?
  check "base pm-config answered as $mode → exit 4" "4" "$rc"
  check "base pm-config answered as $mode → nothing on stdout" "" "$out"
done
out="$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=null pr_gate)"; rc=$?
check "changedFiles null → exit 4 (truncation undetectable)" "4" "$rc"

# The local checkout's policy must never govern a PR — only its base branch.
# Run from a throwaway repo whose OWN pm-config declares everything ci-only;
# the base branch declares no policy, so the answer must be legacy.
cp "$POLICY" "$TMP_DIR/local-copy.md"
LOCAL_REPO="$TMP_DIR/local-repo"
mkdir -p "$LOCAL_REPO/.claude"
git -C "$LOCAL_REPO" init -q
printf '# PM Config\n\n## Review policy\n\n| Tier | Gate |\n|---|---|\n| default | ci-only |\n' > "$LOCAL_REPO/.claude/pm-config.md"
ln -s "$TMP_DIR/gone.md" "$TMP_DIR/dangling-repo-config.md"
DANGLING_REPO="$TMP_DIR/dangling-repo"
mkdir -p "$DANGLING_REPO/.claude"; git -C "$DANGLING_REPO" init -q
ln -s "$TMP_DIR/gone.md" "$DANGLING_REPO/.claude/pm-config.md"
out="$(cd "$DANGLING_REPO" && printf 'docs/a.md' | bash "$SUT" --files-from - 2>/dev/null)"; rc=$?
check "offline mode: dangling pm-config.md symlink → exit 4" "4" "$rc"
check "offline mode: dangling pm-config.md symlink → nothing on stdout" "" "$out"

check "sanity: the throwaway repo's own policy is ci-only offline" "ci-only" \
  "$(cd "$LOCAL_REPO" && printf 'docs/a.md' | bash "$SUT" --files-from - 2>/dev/null)"
printf '# PM Config\n' > "$FAKE_BASE_CONFIG"
check "PR mode ignores the local checkout; base has no policy → legacy" "legacy" \
  "$(cd "$LOCAL_REPO" && FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 pr_gate)"
check "--config overrides the base-branch read in PR mode" "ci-only" \
  "$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 pr_gate --config "$TMP_DIR/local-copy.md")"
# No ambient override: an environment variable must never re-point the gate.
check "CLAUDE_REVIEW_POLICY_FILE in the environment is ignored" "legacy" \
  "$(FAKE_FILES=$'docs/a.md' FAKE_CHANGED=1 CLAUDE_REVIEW_POLICY_FILE="$TMP_DIR/local-copy.md" pr_gate)"
bash "$SUT" 0 >/dev/null 2>&1; check "PR number 0 → exit 2" "2" "$?"

echo
echo "review-tier.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
