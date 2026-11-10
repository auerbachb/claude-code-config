#!/usr/bin/env bash
# Unit tests for zsh-special-name-lint.sh (issue #1556)
#
# Auto-discovered by run-hook-tests.sh — no workflow edit needed.
# Hermetic-fixture pattern, following model-drift-lint.test.sh.
#
# Three layers, because a lint that only proves it stays quiet proves nothing:
#
#   Part 1  fixture behaviour — the hazardous shapes must FAIL, the look-alike
#           shapes (jq path(), --path flags, script_path, prose, non-shell
#           fences) must PASS, and both canaries must trip.
#   Part 2  real-corpus controls — the live repo passes, AND a planted pre-fix
#           run_script() block makes it fail. Without the second half the first
#           half is satisfied by a lint that can never fire.
#   Part 3  runtime proof under an actual zsh: the pre-fix helper shape really
#           does die with `env: bash: No such file or directory` (rc 127) and
#           the renamed shape really does succeed, with the identical file
#           under bash as the control. SKIPPED, and reported as skipped, when
#           no zsh is installed — never silently counted as a pass.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
LINT="${REPO_ROOT}/.github/scripts/zsh-special-name-lint.sh"

if [ ! -f "$LINT" ]; then
  echo "FAIL — lint script not found at $LINT"
  exit 1
fi

TMP_ROOT="$(mktemp -d -t zsh-special-name-lint.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
case_num=0
skips=0

ok()   { echo "ok   — $1"; }
bad()  { echo "FAIL — $1"; failures=$((failures + 1)); }

# A minimal fixture: one clean Markdown file carrying a shell fence, so the
# vacuity canary is satisfied and each case only adds what it is testing.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/docs"
  cat > "$dir/docs/clean.md" <<'CLEAN'
# Clean doc

```bash
run_script() {
  local name="$1"; shift
  local script_path
  script_path=$(resolve_script "$name") || return 127
  "$script_path" "$@"
}
```
CLEAN
}

# expect NAME WANT_EXIT WANT_REGEX  (fixture body arrives on stdin as extra.md)
expect() {
  local name="$1" want="$2" want_re="$3"
  case_num=$((case_num + 1))
  local dir="${TMP_ROOT}/case${case_num}"
  make_fixture "$dir"
  cat > "$dir/docs/extra.md"

  local out got
  out=$(cd "$dir" && bash "$LINT" 2>&1) && got=0 || got=$?

  if [ "$got" -ne "$want" ]; then
    bad "${name}: expected exit ${want}, got ${got}"
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  if [ -n "$want_re" ] && ! grep -qE "$want_re" <<<"$out"; then
    bad "${name}: exit ${got} as expected, but output did not match /${want_re}/"
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  ok "$name"
}

echo "=== Part 1 — fixture behaviour ==="

# --- the defect itself ------------------------------------------------------
expect "pre-fix run_script() block is rejected" 1 "zsh-special name 'path'" <<'MD'
```bash
run_script() {
  local name="$1"; shift
  local path
  if ! path=$(resolve_script "$name"); then
    return 127
  fi
  "$path" "$@"
}
```
MD

expect "renamed run_script() block passes" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
run_script() {
  local name="$1"; shift
  local script_path
  if ! script_path=$(resolve_script "$name"); then
    return 127
  fi
  "$script_path" "$@"
}
```
MD

# --- every recognised declaration form --------------------------------------
expect "bare assignment in command position" 1 "zsh-special name 'path'" <<'MD'
```sh
path=/usr/local/bin
```
MD

expect "assignment after a leading keyword" 1 "zsh-special name 'path'" <<'MD'
```bash
if ! path=$(which jq); then echo no; fi
```
MD

expect "for-loop variable" 1 "zsh-special name 'path'" <<'MD'
```bash
for path in a b c; do echo "$path"; done
```
MD

expect "read builtin target" 1 "zsh-special name 'path'" <<'MD'
```bash
read -r path < /tmp/x
```
MD

expect "declare with a flag" 1 "zsh-special name 'fpath'" <<'MD'
```bash
declare -a fpath
```
MD

expect "multi-name local declaration" 1 "zsh-special name 'path'" <<'MD'
```bash
foo() { local name="$1" path candidate; }
```
MD

expect "assignment on the far side of a separator" 1 "zsh-special name 'path'" <<'MD'
```bash
mkdir -p /tmp/x && path=/tmp/x
```
MD

# --- tiers ------------------------------------------------------------------
expect "tied-array name is reported as tied" 1 "zsh-special name 'cdpath' .* ties" <<'MD'
```bash
local cdpath=/tmp
```
MD

expect "read-only name is reported as fatal" 1 "zsh-special name 'status' .* refuses" <<'MD'
```bash
status=$(gh pr view 1 --json state)
```
MD

expect "reserved shell state is reported" 1 "zsh-special name 'functions'" <<'MD'
```bash
functions=/tmp/f
```
MD

expect "positional-array name argv is reported" 1 "zsh-special name 'argv'" <<'MD'
```bash
local argv=/tmp/x
```
MD

# --- look-alikes that must NOT fire -----------------------------------------
expect "jq path() and a --path flag are not assignments" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
jq -r 'path(..) | join(".")' state.json
handoff-state.sh --owner-repo o/r --path 42
gh api repos/o/r/contents --jq '.[].path'
```
MD

expect "suffixed names are not the special name" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
script_path=/tmp/a
log_path="$1"
local out_path
MY_PATH=/tmp/b
```
MD

expect "reads of \$path are not assignments" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
echo "$path"
printf '%s\n' "${path}"
```
MD

expect "status= inside a quoted jq format string" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
jq -r '.merge_state | "mergeable=\(.mergeable), status=\(.mergeStateStatus)"' "$VERIFY"
echo "found status=completed"
```
MD

expect "trailing comment mentioning path" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
local script_path       # NOT `path`: zsh ties lowercase `path` to `PATH`
```
MD

expect "non-shell fences are not scanned" 0 "zsh-special-name-lint: OK" <<'MD'
```python
path = "/tmp/x"
```

```json
{"path": "/tmp/x"}
```

```text
local path
```
MD

expect "prose outside any fence is not scanned" 0 "zsh-special-name-lint: OK" <<'MD'
The helper used `local path`, and a bare path= assignment, which broke PATH.

| field | value |
|-------|-------|
| path= | /tmp  |
MD

expect "opt-out marker suppresses a deliberate example" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
local path   # zsh-special-name-ok — this block documents the broken form
```
MD

# --- attribute-style fence info strings -------------------------------------
# Quarto/R Markdown write ```{bash}; Pandoc writes ```{.bash}. Both are shell
# fences, so neither may slip past the scanner unscanned.
expect "Quarto-style {bash} fence is scanned" 1 "zsh-special name 'path'" <<'MD'
```{bash}
local path
```
MD

expect "Pandoc-style {.bash} fence is scanned" 1 "zsh-special name 'path'" <<'MD'
```{.bash}
local path
```
MD

expect "Pandoc classes after the language are scanned" 1 "zsh-special name 'path'" <<'MD'
```{.sh .numberLines}
local path
```
MD

expect "attribute fence for another language is still skipped" 0 "zsh-special-name-lint: OK" <<'MD'
```{.python}
path = "/tmp/x"
```
MD

# --- backslash line continuations -------------------------------------------
# One command split across physical lines must be judged as one command: the
# continuation of a *command* carries arguments (no assignment), while the
# continuation of a *declaration* still declares.
expect "continued argument is not a command-position assignment" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
some_command \
  path=value
```
MD

expect "continued declaration is still reported" 1 "zsh-special name 'path'" <<'MD'
```bash
local name="$1" \
      path candidate
```
MD

expect "opt-out marker on either continued line suppresses the command" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
local name="$1" \
      path candidate   # zsh-special-name-ok — documents the broken form
```
MD

# --- read builtin flag arguments --------------------------------------------
# `-p` takes a prompt, not a variable name; `-a` really does name an array.
expect "read -p prompt word is not a bound name" 0 "zsh-special-name-lint: OK" <<'MD'
```bash
read -p path value
```
MD

expect "read -rp still binds its trailing NAME" 1 "zsh-special name 'path'" <<'MD'
```bash
read -rp prompt path
```
MD

expect "read -a array name is still reported" 1 "zsh-special name 'path'" <<'MD'
```bash
read -a path
```
MD

# --- canaries ---------------------------------------------------------------
canary_dir="${TMP_ROOT}/canary-nofences"
mkdir -p "$canary_dir"
printf '# Doc\n\nNo code fences at all.\n' > "$canary_dir/only.md"
out=$(cd "$canary_dir" && bash "$LINT" 2>&1) && got=0 || got=$?
if [ "$got" -eq 1 ] && grep -q "0 shell code fences" <<<"$out"; then
  ok "vacuity canary: zero shell fences fails instead of passing green"
else
  bad "vacuity canary: expected exit 1 with the zero-fence message, got exit ${got}"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

canary_dir2="${TMP_ROOT}/canary-nomd"
mkdir -p "$canary_dir2"
printf 'not markdown\n' > "$canary_dir2/readme.txt"
out=$(cd "$canary_dir2" && bash "$LINT" 2>&1) && got=0 || got=$?
if [ "$got" -eq 1 ] && grep -q "no Markdown files" <<<"$out"; then
  ok "discovery canary: an empty corpus fails instead of passing green"
else
  bad "discovery canary: expected exit 1 with the no-Markdown message, got exit ${got}"
  printf '%s\n' "$out" | sed 's/^/       /'
fi

# --- usage contract ---------------------------------------------------------
out=$(bash "$LINT" --help 2>&1) && got=0 || got=$?
if [ "$got" -eq 0 ] && grep -q 'Usage:' <<<"$out"; then
  ok "--help exits 0 and prints usage"
else
  bad "--help: expected exit 0 with a Usage: line, got exit ${got}"
fi
bash "$LINT" --nope >/dev/null 2>&1 && got=0 || got=$?
if [ "$got" -eq 2 ]; then
  ok "unknown flag exits 2"
else
  bad "unknown flag: expected exit 2, got ${got}"
fi

echo
echo "=== Part 2 — real-corpus controls ==="

if ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  ok "live repo passes the lint"
else
  bad "live repo fails the lint (unexpected)"
  ( cd "$REPO_ROOT" && bash "$LINT" 2>&1 | sed 's/^/       /' ) || true
fi

# Revert-verify: plant the pre-fix shape in the REAL tree and require a failure.
# Proves the lint is wired to the real corpus, not just to fixtures.
PLANTED="${REPO_ROOT}/.zsh-special-name-lint-probe.md"
cleanup_planted() { rm -f "$PLANTED"; rm -rf "$TMP_ROOT"; }
trap cleanup_planted EXIT
cat > "$PLANTED" <<'PROBE'
# temporary lint probe

```bash
run_script() {
  local name="$1"; shift
  local path
  path=$(resolve_script "$name")
  "$path" "$@"
}
```
PROBE
if ( cd "$REPO_ROOT" && bash "$LINT" >/dev/null 2>&1 ); then
  bad "revert-verify: lint passed with a planted pre-fix block — it is not scanning the real corpus"
else
  ok "revert-verify: lint fails on a planted pre-fix block"
fi
rm -f "$PLANTED"

# The four live agent templates must no longer carry the hazardous name.
offenders=""
for t in phase-a-fixer phase-b-reviewer phase-c-merger pm-worker; do
  f="${REPO_ROOT}/.claude/agents/${t}.md"
  [ -f "$f" ] || { offenders="${offenders} ${t}(missing)"; continue; }
  if grep -qE '^[[:space:]]*local[[:space:]]+path[[:space:]]*$|^[[:space:]]*(if ! )?path=' "$f"; then
    offenders="${offenders} ${t}"
  fi
done
if [ -z "$offenders" ]; then
  ok "all four agent templates use a zsh-safe variable name"
else
  bad "agent templates still assign 'path':${offenders}"
fi

echo
echo "=== Part 3 — runtime proof under a real zsh ==="

ZSH_BIN=""
for cand in /bin/zsh /usr/bin/zsh /usr/local/bin/zsh /opt/homebrew/bin/zsh; do
  [ -x "$cand" ] && { ZSH_BIN="$cand"; break; }
done
[ -n "$ZSH_BIN" ] || ZSH_BIN="$(command -v zsh 2>/dev/null || true)"

REPRO="${TMP_ROOT}/repro.sh"
cat > "$REPRO" <<'REPRO_EOF'
# Runs under whichever shell invokes it. Prints two "NAME rc=N" lines.
TD=$(mktemp -d)
printf '%s\n' '#!/usr/bin/env bash' 'echo helper-ran' > "$TD/helper.sh"
chmod +x "$TD/helper.sh"
resolve_script() { echo "$TD/$1"; }

buggy() {
  local name="$1"; shift
  local path
  path=$(resolve_script "$name")
  "$path" "$@"
}
fixed() {
  local name="$1"; shift
  local script_path
  script_path=$(resolve_script "$name")
  "$script_path" "$@"
}

buggy helper.sh > /dev/null 2> "$TD/buggy.err"
echo "BUGGY rc=$?"
echo "BUGGY_ERR $(head -1 "$TD/buggy.err")"
fixed helper.sh > /dev/null 2> "$TD/fixed.err"
echo "FIXED rc=$?"
echo "FIXED_ERR $(head -1 "$TD/fixed.err")"
REPRO_EOF

if [ -n "$ZSH_BIN" ]; then
  zout="$("$ZSH_BIN" "$REPRO" 2>&1)"
  if grep -q '^BUGGY rc=127$' <<<"$zout"; then
    ok "zsh: the pre-fix 'local path' helper cannot exec its own target (rc 127)"
  else
    bad "zsh: expected 'BUGGY rc=127', got: $(printf '%s' "$zout" | tr '\n' ' ')"
  fi
  if grep -q '^FIXED rc=0$' <<<"$zout"; then
    ok "zsh: the renamed 'local script_path' helper runs cleanly (rc 0)"
  else
    bad "zsh: expected 'FIXED rc=0', got: $(printf '%s' "$zout" | tr '\n' ' ')"
  fi

  # The stderr the corruption actually produces — the misleading symptom that
  # made this look like a missing helper rather than a destroyed PATH. Paired
  # with the renamed variant, which must produce no stderr at all.
  buggy_err="$(printf '%s\n' "$zout" | sed -n 's/^BUGGY_ERR //p')"
  fixed_err="$(printf '%s\n' "$zout" | sed -n 's/^FIXED_ERR //p')"
  # GNU env quotes the name (env: 'bash': No such ...) where BSD env does not,
  # so match loosely around it rather than pinning the macOS spelling.
  if grep -qE 'bash.*No such file or directory' <<<"$buggy_err" \
     && [ -z "$(printf '%s' "$fixed_err" | tr -d '[:space:]')" ]; then
    ok "zsh: the corruption surfaces as 'env: bash: No such file or directory' (silent for the renamed variant)"
  else
    bad "zsh: expected the env/bash lookup failure only from the buggy shape (buggy='${buggy_err}' fixed='${fixed_err}')"
  fi
else
  skips=$((skips + 1))
  echo "skip — no zsh on this machine; the runtime repro did not run (it does run on the macOS CI job)"
fi

# bash control: the identical file is harmless under bash, which is why every
# .sh file in this repo can keep using `local path`.
bout="$(bash "$REPRO" 2>&1)"
if grep -q '^BUGGY rc=0$' <<<"$bout" && grep -q '^FIXED rc=0$' <<<"$bout"; then
  ok "bash control: both helper shapes work — the defect is zsh-specific"
else
  bad "bash control: expected both rc=0, got: $(printf '%s' "$bout" | tr '\n' ' ')"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "zsh-special-name-lint.test: ${failures} failure(s)"
  exit 1
fi
echo "OK: zsh-special-name-lint tests passed (${case_num} fixtures, ${skips} skipped)"
