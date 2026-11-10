#!/usr/bin/env bash
# Unit tests for zsh-optional-flag-lint.sh (issue #1857)
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.
#
#   Part 1  fixture behaviour — the idiom (plain, nested, colon-less, and a
#           multi-word flag string in a scalar) FAILS; the safe shapes
#           (single-word expansion, double-quoted strings, comments, heredoc
#           bodies, arrays, the opt-out marker) PASS; both canaries trip.
#   Part 2  real-corpus controls — the live skills pass, AND planting the
#           pre-fix /wrap Step 3.14 line into a copy makes the lint fail.
#   Part 3  runtime proof: under zsh the idiom reaches a stub as ONE argument
#           and the array form as two (a value with a space stays one); the
#           empty guarded array is zero arguments under /bin/bash with set -u.
#           A missing shell is reported as SKIPPED, never counted as a pass.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
LINT="${REPO_ROOT}/.github/scripts/zsh-optional-flag-lint.sh"
[ -f "$LINT" ] || { echo "FAIL — lint script not found at $LINT"; exit 1; }

TMP_ROOT="$(mktemp -d -t zsh-optional-flag-lint.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
skips=0
case_num=0
ok()  { echo "ok   — $1"; }
bad() { echo "FAIL — $1"; failures=$((failures + 1)); }

# One clean skill with a shell fence plus one agent definition, so the
# canaries are satisfied and each case only adds what it tests.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.claude/skills/clean" "$dir/.claude/agents"
  cat > "$dir/.claude/skills/clean/SKILL.md" <<'CLEAN'
# Clean

```bash
ARGS=()
[ -n "${REPO:-}" ] && ARGS=(--repo "$REPO")
helper ${ARGS[@]+"${ARGS[@]}"} --json
```
CLEAN
  printf '# Agent\n\nNo shell here.\n' > "$dir/.claude/agents/agent.md"
}

# expect NAME WANT_EXIT WANT_REGEX — fixture body on stdin becomes a skill's
# references/extra.md (proving references/ is in scope).
expect() {
  local name="$1" want="$2" want_re="$3"
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  mkdir -p "$dir/.claude/skills/clean/references"
  cat > "$dir/.claude/skills/clean/references/extra.md"
  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?
  if [ "$got" -ne "$want" ]; then
    bad "${name}: expected exit ${want}, got ${got}"; printf '%s\n' "$out" | sed 's/^/       /'; return
  fi
  if [ -n "$want_re" ] && ! grep -qE -- "$want_re" <<<"$out"; then
    bad "${name}: output did not match /${want_re}/"; printf '%s\n' "$out" | sed 's/^/       /'; return
  fi
  ok "$name"
}

echo "=== Part 1 — fixture behaviour ==="

expect "the idiom is rejected" 1 'extra.md:2: \$\{REPO:\+--repo "\$REPO"\}' <<'MD'
```bash
release-sweep.sh ${REPO:+--repo "$REPO"} --json
```
MD

expect "the nested idiom is rejected" 1 'OTHER:\+--window-issues' <<'MD'
```bash
check.sh ${DL:+${OTHER:+--window-issues "$OTHER"}}
```
MD

expect "the colon-less form is rejected" 1 'X\+-f "\$X"' <<'MD'
```sh
tool ${X+-f "$X"}
```
MD

expect "inside \$( ) within an assignment is rejected" 1 'DEDUP_EXCLUDE' <<'MD'
```bash
OUT=$("$H" "$kw" ${DEDUP_EXCLUDE:+--exclude "$DEDUP_EXCLUDE"}) || rc=$?
```
MD

expect "inside \$( ) nested in a double-quoted string is rejected" 1 'GH_USER' <<'MD'
```bash
echo "result: $(triage --json ${GH_USER:+--author "$GH_USER"})"
```
MD

expect "a multi-word flag string expanded bare is rejected" 1 'flag string kept in a scalar' <<'MD'
```bash
REPO_FLAG="--repo $OWNER_NAME"
gh pr view "$N" $REPO_FLAG --json number
```
MD

expect "an expansion continuing onto the next line is rejected" 1 'extra.md:2: \$\{REPO:\+--repo' <<'MD'
```bash
helper ${REPO:+--repo
  "$REPO"} --json
```
MD

expect "a nested multi-line expansion is reported once" 1 '1 error\(s\)' <<'MD'
```bash
helper ${A:+${B:+--flag "$B"
}}
```
MD

expect "a flag string reassigned to a single word passes" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
REPO_FLAG="--repo $OWNER_NAME"
REPO_FLAG="--all-repos"
helper $REPO_FLAG --json
```
MD

expect "a re-marked flag string after a safe value is rejected" 1 'flag string kept in a scalar' <<'MD'
```bash
F="--json"
F="--repo $X"
helper $F
```
MD

expect "an untagged fence is scanned" 1 'optional|ONE argument' <<'MD'
```
helper ${A:+--a "$A"}
```
MD

expect "single-word expansion passes" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
measure.sh ${ALL_REPOS:+--all-repos} --json
```
MD

expect "expansions inside double-quoted strings pass" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
echo "Could not find #$N${REPO:+ in $REPO}" >&2
msg="${X:+--repo $X}"
```
MD

expect "a whitespace word that is not a flag passes" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
printf '%s\n' ${X:+$X and more}
```
MD

expect "comments and heredoc bodies pass" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
# old shape was ${REPO:+--repo "$REPO"} — do not reintroduce
cat <<'EOF'
helper ${REPO:+--repo "$REPO"}
EOF
```
MD

expect "a single-word flag string in a scalar passes" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
JSON_FLAG="--json"
helper $JSON_FLAG
```
MD

expect "non-shell fences and prose pass" 0 'zsh-optional-flag-lint: OK' <<'MD'
Prose mentioning ${REPO:+--repo "$REPO"} is fine.

```python
x = '${REPO:+--repo "$REPO"}'
```
MD

expect "the opt-out marker suppresses one line" 0 'zsh-optional-flag-lint: OK' <<'MD'
```bash
helper ${REPO:+--repo "$REPO"}   # zsh-optional-flag-ok
```
MD

# Canary: no shell fences anywhere.
case_num=$((case_num + 1)); dir="${TMP_ROOT}/case${case_num}"
mkdir -p "$dir/.claude/skills/x" "$dir/.claude/agents"
printf '# X\n\nprose only\n' > "$dir/.claude/skills/x/SKILL.md"
printf '# A\n' > "$dir/.claude/agents/a.md"
out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?
if [ "$got" -eq 1 ] && grep -q '0 shell fences' <<<"$out"; then ok "zero-fence canary trips"; else bad "zero-fence canary: exit $got"; fi

# Canary: a guarded surface is missing.
case_num=$((case_num + 1)); dir="${TMP_ROOT}/case${case_num}"
make_fixture "$dir"; rm -rf "$dir/.claude/agents"
out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?
if [ "$got" -eq 3 ]; then ok "missing agents/ exits 3"; else bad "missing agents/: exit $got"; fi

echo "=== Part 2 — real corpus ==="

out=$(cd "$REPO_ROOT" && bash "$LINT" 2>&1) && got=0 || got=$?
if [ "$got" -eq 0 ]; then ok "live skills and agents pass"; else bad "live corpus: exit $got"; printf '%s\n' "$out" | sed 's/^/       /'; fi

copy="${TMP_ROOT}/corpus"
mkdir -p "$copy/.claude"
cp -R "$REPO_ROOT/.claude/skills" "$REPO_ROOT/.claude/agents" "$copy/.claude/"
printf '\n```bash\nSWEEP_OUT=$("$RELEASE_SWEEP" ${MERGED_REPO:+--repo "$MERGED_REPO"} --json 2>/dev/null) || true\n```\n' \
  >> "$copy/.claude/skills/wrap/SKILL.md"
out=$(cd "$copy" && bash "$LINT" 2>&1) && got=0 || got=$?
if [ "$got" -eq 1 ] && grep -q 'wrap/SKILL.md' <<<"$out"; then ok "planted pre-fix /wrap line fails"; else bad "planted control: exit $got"; fi

echo "=== Part 3 — runtime proof ==="

stub="${TMP_ROOT}/stub.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$#"\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' > "$stub"
chmod +x "$stub"

ZSH_BIN=""
for c in /bin/zsh /usr/bin/zsh /opt/homebrew/bin/zsh /usr/local/bin/zsh; do
  [ -x "$c" ] && { ZSH_BIN="$c"; break; }
done
if [ -z "$ZSH_BIN" ]; then
  echo "SKIP — no zsh installed; the runtime half did not run (the static lint above still did)"
  skips=$((skips + 1))
else
  got=$(STUB="$stub" "$ZSH_BIN" -c 'x=owner/name; "$STUB" ${x:+--repo "$x"} | head -1')
  [ "$got" = "1" ] && ok "zsh: the idiom collapses to ONE argument (the original symptom)" || bad "zsh idiom: got $got args"
  got=$(STUB="$stub" "$ZSH_BIN" -c 'x="owner name"; A=(); [ -n "$x" ] && A=(--repo "$x"); "$STUB" ${A[@]+"${A[@]}"}' | tr '\n' ' ')
  [ "$got" = "2 [--repo] [owner name] " ] && ok "zsh: array form is two arguments, spaced value intact" || bad "zsh array: got '$got'"
  got=$(STUB="$stub" "$ZSH_BIN" -c 'set -u; A=(); "$STUB" ${A[@]+"${A[@]}"}')
  [ "$got" = "0" ] && ok "zsh: empty array is zero arguments under set -u" || bad "zsh empty: got '$got'"
fi

for B in /bin/bash "$(command -v bash)"; do
  [ -x "$B" ] || continue
  ver=$("$B" -c 'echo "${BASH_VERSION%%(*}"')
  got=$(STUB="$stub" "$B" -c 'set -u; x="owner name"; A=(); [ -n "$x" ] && A=(--repo "$x"); "$STUB" ${A[@]+"${A[@]}"}' | tr '\n' ' ')
  [ "$got" = "2 [--repo] [owner name] " ] && ok "bash ${ver}: array form is two arguments" || bad "bash ${ver} array: got '$got'"
  got=$(STUB="$stub" "$B" -c 'set -u; A=(); "$STUB" ${A[@]+"${A[@]}"}' 2>&1)
  [ "$got" = "0" ] && ok "bash ${ver}: empty guarded array is safe under set -u" || bad "bash ${ver} empty: got '$got'"
done

echo
if [ "$failures" -gt 0 ]; then
  echo "zsh-optional-flag-lint.test: ${failures} failure(s), ${skips} skipped"
  exit 1
fi
echo "zsh-optional-flag-lint.test: all passed (${skips} skipped)"
