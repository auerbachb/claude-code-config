#!/usr/bin/env bash
# slow-read-cache.test.sh — Offline tests for lib/slow-read-cache.sh and its three
# consumers (issue #2443, slice 3 of #2421): CODEOWNERS (merge-gate.sh), pm-config.md
# at the base (review-tier.sh) and the base branch's required status checks
# (required-checks.sh).
# catalog: tests — Short-lived reuse of the slow-changing GitHub reads: each key, each invalidation, corrupt-file and failed-read fallbacks, verdict identical with and without the cache
#
# The gate decides whether unreviewed code merges, so every scenario asserts both
# halves: the reuse (zero live reads on a hit) and the refusal (a live read, and
# the right answer, on every doubt). No test calls GitHub: `gh` is a stub.
# Run from repo root: bash .claude/scripts/tests/slow-read-cache.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

export SLOW_READ_CACHE_DIR="$HOME/.claude/slow-read-cache"
CALLS="$TMP/calls"
TIPFILE="$TMP/tip"
TIPSEQ="$TMP/tipseq"

mv "$BIN/gh" "$BIN/gh.base"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS=" $* "
case "$ARGS" in
  " api user --jq .login ")
    echo "user" >> "$CALLS"
    echo "${FAKE_VIEWER:-solouser}"; exit 0 ;;
  *"ref(qualifiedName"*)
    echo "tip" >> "$CALLS"
    [[ -n "${FAKE_TIP_FAIL:-}" ]] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    if [[ -s "$TIPSEQ" ]]; then   # one value per call, then the last value repeats
      v="$(head -1 "$TIPSEQ")"; n="$(wc -l < "$TIPSEQ" | tr -d ' ')"
      [[ "$n" -gt 1 ]] && tail -n +2 "$TIPSEQ" > "$TIPSEQ.n" && mv "$TIPSEQ.n" "$TIPSEQ"
      printf '%s' "$v"; exit 0
    fi
    cat "$TIPFILE"; exit 0 ;;
  *" repos/solo/repo/contents/.claude/pm-config.md "*)
    echo "pmconfig" >> "$CALLS"; echo "$ARGS" >> "$CALLS.args"
    [[ "${FAKE_TIER_FAIL:-0}" == "1" ]] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [[ -z "${FAKE_PM_CONFIG:-}" ]] && { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -cn --arg c "$(printf '%s' "$FAKE_PM_CONFIG" | base64 | tr -d '\n')" \
      '{type:"file", encoding:"base64", content:$c}'
    exit 0 ;;
  *" repos/solo/repo/contents/"*CODEOWNERS" "*)
    echo "codeowners" >> "$CALLS"; echo "$ARGS" >> "$CALLS.args"
    case "${FAKE_CO_MODE:-404}" in
      500) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
      found)
        case "$ARGS" in
          *" repos/solo/repo/contents/.github/CODEOWNERS "*)
            jq -cn --arg c "$(printf '%s\n' "${FAKE_CODEOWNERS:-* @coderabbitai}" | base64 | tr -d '\n')" '{content:$c}'; exit 0 ;;
        esac ;;
    esac
    echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *" pr view 1 --repo solo/repo --json labels,changedFiles "*)
    jq -cn '{labels: [], changedFiles: 0}'; exit 0 ;;
  *" repos/solo/repo/pulls/1/files?per_page=100 "*)
    exit 0 ;;
  *" repos/solo/repo/branches/main/protection/required_status_checks "*)
    echo "protection" >> "$CALLS"; exec "$(dirname "$0")/gh.base" "$@" ;;
  *" repos/solo/repo/branches/main "*)
    echo "branch" >> "$CALLS"; exec "$(dirname "$0")/gh.base" "$@" ;;
esac
exec "$(dirname "$0")/gh.base" "$@"
EOF
chmod +x "$BIN/gh"
export CALLS TIPFILE TIPSEQ

calls() { local n; n="$( [[ -f "$CALLS" ]] && grep -c "^$1\$" "$CALLS" || true )"; echo "${n:-0}"; }
reset_calls() { : > "$CALLS"; }
set_tip() { printf '%s' "$1" > "$TIPFILE"; rm -f "$TIPSEQ"; }
TIP_A="aaaaaaaa00000000000000000000000000000001"
TIP_B="bbbbbbbb00000000000000000000000000000002"
TIP_C="cccccccc00000000000000000000000000000003"
set_tip "$TIP_A"
kind_files() { find "$SLOW_READ_CACHE_DIR" -type f -name "*__$1.*.json" 2>/dev/null | wc -l | tr -d ' '; }
cache_files() { find "$SLOW_READ_CACHE_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
reset_cache() { rm -rf "$SLOW_READ_CACHE_DIR"; reset_calls; }
age_files() { # seconds: rewrite every entry as saved that long ago
  local f
  for f in "$SLOW_READ_CACHE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    jq -c --argjson a "$1" '.saved_epoch = (.saved_epoch - $a)' "$f" > "$f.n" && mv "$f.n" "$f"
  done
}

# ---------------------------------------------------------------- merge-gate
OUT=""
run_gate() {
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS='{"check_runs":[]}' FAKE_REVIEWS='[]' "$SUT" 1 --reviewer cr 2>/dev/null) || true
}
bots() { jq -c '.code_owner_bots' <<<"$OUT"; }
verdict() { jq -c '{met, missing, code_owner_bots, review_tier, required_contexts}' <<<"$OUT"; }

echo "== CODEOWNERS (merge-gate.sh)"
export FAKE_CO_MODE=found FAKE_CODEOWNERS="* @coderabbitai"
reset_cache; rm -f "$CALLS.args"; run_gate
check_eq '["coderabbitai[bot]"]' "$(bots)" "cold: live read finds the code owner"
check_eq 2 "$(calls codeowners)" "cold: two live path reads (root 404, .github found)"
V_COLD="$(verdict)"
check_eq 2 "$(grep -c "CODEOWNERS -f ref=$TIP_A " "$CALLS.args")" "cold: live reads are pinned to the commit the key names (CODEOWNERS)"
reset_calls; run_gate
check_eq '["coderabbitai[bot]"]' "$(bots)" "warm: same code owner"
check_eq 0 "$(calls codeowners)" "warm: zero CODEOWNERS reads (reused)"
check_eq "$V_COLD" "$(verdict)" "warm: whole gate verdict identical to the cold run"

reset_calls; set_tip "$TIP_B"; FAKE_CODEOWNERS="* @greptile-apps" run_gate
check_eq '["greptile-apps[bot]"]' "$(bots)" "base moved: new CODEOWNERS wins, old one never used"
check_eq 2 "$(calls codeowners)" "base moved: live read"
set_tip "$TIP_A"
reset_calls; run_gate
check_eq 2 "$(calls codeowners)" "tip back to an older value: entry was replaced, so live again (never a stale hit)"

reset_calls; age_files 301; run_gate
check_eq 2 "$(calls codeowners)" "entry older than the 300s maximum: live read"
check_eq '["coderabbitai[bot]"]' "$(bots)" "stale entry: answer still right"

f="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*codeowners*' | head -1)"
printf '{not json' > "$f"
reset_calls; run_gate
check_eq 2 "$(calls codeowners)" "corrupt file: live read"
check_eq '["coderabbitai[bot]"]' "$(bots)" "corrupt file: right answer"
printf '{"schema":1,"kind":"codeowners","value":5}' > "$f"
reset_calls; run_gate
check_eq 2 "$(calls codeowners)" "partial entry (no repo/key/viewer, wrong value type): live read"

reset_calls; FAKE_VIEWER=otheruser run_gate
check_eq 2 "$(calls codeowners)" "different signed-in login: miss"

reset_cache; FAKE_TIP_FAIL=1 run_gate
check_eq '["coderabbitai[bot]"]' "$(bots)" "tip unreadable: live read, right answer"
check_eq 0 "$(cache_files)" "tip unreadable: nothing stored"
reset_cache; printf 'not-a-sha\n' > "$TIPSEQ"; run_gate
check_eq 0 "$(cache_files)" "tip answer is not a 40-hex SHA: nothing stored"

# Call order inside the gate: review-tier reads the tip twice (before/after its
# pm-config read), then CODEOWNERS reads it twice. A,A,A,B moves the base during
# the CODEOWNERS read only.
reset_cache; printf '%s\n%s\n%s\n%s\n' "$TIP_A" "$TIP_A" "$TIP_A" "$TIP_B" > "$TIPSEQ"; run_gate
check_eq 0 "$(kind_files codeowners)" "base moved while the file was read (tip before != after): nothing stored"
check_eq 1 "$(kind_files pm-config)" "(control) the pm-config read, whose tip did not move, was stored"
set_tip "$TIP_A"

echo "== CODEOWNERS: a failed read is never stored"
reset_cache; FAKE_CO_MODE=500 run_gate
check_eq '[]' "$(bots)" "rate-limited/5xx read: behaves as before (no code owner)"
check_eq 0 "$(kind_files codeowners)" "failed read: nothing stored"
reset_calls; FAKE_CO_MODE=found run_gate
check_eq '["coderabbitai[bot]"]' "$(bots)" "next run reads live and sees the real owner (the failure was not remembered)"

echo "== CODEOWNERS: definite absence"
reset_cache; FAKE_CO_MODE=404 run_gate
check_eq '[]' "$(bots)" "all three paths 404: no code owner"
check_eq 3 "$(calls codeowners)" "cold absence: three reads"
check_eq 1 "$(kind_files codeowners)" "definite absence is stored"
reset_calls; FAKE_CO_MODE=404 run_gate
check_eq 0 "$(calls codeowners)" "warm absence: zero reads"
check_eq '[]' "$(bots)" "warm absence: still no code owner"
set_tip "$TIP_C"; reset_calls; FAKE_CO_MODE=found run_gate
check_eq '["coderabbitai[bot]"]' "$(bots)" "a new base commit that adds CODEOWNERS is seen at once (absence never outlives a base change)"
set_tip "$TIP_A"

# ---------------------------------------------------------------- review-tier
echo "== pm-config at the base (review-tier.sh)"
TIER="$REPO_ROOT/.claude/scripts/review-tier.sh"
POLICY=$'# Config\n\n## Review policy\n\n| Tier | Gate | Paths | Labels |\n|------|------|-------|--------|\n| default | ci-only | | |\n'
POLICY2=$'# Config\n\n## Review policy\n\n| Tier | Gate | Paths | Labels |\n|------|------|-------|--------|\n| default | full | | |\n'
run_tier() { OUT=$(PATH="$BIN:$PATH" "$TIER" 1 --repo solo/repo --base main --json 2>/dev/null); TIER_RC=$?; }
export FAKE_PR_FILES_JSON='[]'
reset_cache; rm -f "$CALLS.args"; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq ci-only "$(jq -r .gate <<<"$OUT")" "cold: policy read live"
check_eq 1 "$(calls pmconfig)" "cold: one live pm-config read"
T_COLD="$OUT"
check_eq 1 "$(grep -c "contents/.claude/pm-config.md -f ref=$TIP_A " "$CALLS.args")" "cold: the pm-config read is pinned to the commit the key names"
reset_calls; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq 0 "$(calls pmconfig)" "warm: zero pm-config reads"
check_eq "$T_COLD" "$OUT" "warm: tier output byte-identical to the live run"
reset_calls; set_tip "$TIP_B"; FAKE_PM_CONFIG="$POLICY2" run_tier
check_eq full "$(jq -r .gate <<<"$OUT")" "base moved: the new policy applies, the old one is never used"
check_eq 1 "$(calls pmconfig)" "base moved: live read"
set_tip "$TIP_A"
reset_calls; age_files 301; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq 1 "$(calls pmconfig)" "stale entry: live read"
f="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*pm-config*' | head -1)"
printf '' > "$f"; reset_calls; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq 1 "$(calls pmconfig)" "empty file: live read"
check_eq ci-only "$(jq -r .gate <<<"$OUT")" "empty file: right answer"
f="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*pm-config*' | head -1)"
jq -c '.value = "{\"present\":true}"' "$f" > "$f.n" && mv "$f.n" "$f"
reset_calls; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq 1 "$(calls pmconfig)" "entry says present but carries no text: live read, never an empty policy"
check_eq ci-only "$(jq -r .gate <<<"$OUT")" "entry without text: right answer"
reset_cache; FAKE_TIER_FAIL=1 FAKE_PM_CONFIG="$POLICY" run_tier
check_eq 4 "$TIER_RC" "failed read: exits 4 exactly as without the cache"
check_eq 0 "$(cache_files)" "failed read: nothing stored"
reset_calls; FAKE_PM_CONFIG="" run_tier
check_eq 1 "$(calls pmconfig)" "404 (no file): live read"
check_eq 1 "$(cache_files)" "404 is a definite answer and is stored"
reset_calls; FAKE_PM_CONFIG="" run_tier
check_eq 0 "$(calls pmconfig)" "stored 404: zero reads"
set_tip "$TIP_B"; reset_calls; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq ci-only "$(jq -r .gate <<<"$OUT")" "a base commit that adds the file is seen at once"
set_tip "$TIP_A"
reset_cache; printf '%s\n%s\n' "$TIP_A" "$TIP_B" > "$TIPSEQ"; FAKE_PM_CONFIG="$POLICY" run_tier
check_eq 0 "$(cache_files)" "base moved during the read: nothing stored"
set_tip "$TIP_A"

# ------------------------------------------------------------ required checks
echo "== required status checks (required-checks.sh)"
REQ="$REPO_ROOT/.claude/scripts/required-checks.sh"
run_req() { OUT=$(PATH="$BIN:$PATH" "$REQ" --repo solo/repo --base main 2>/dev/null); }
PROT='{"strict":true,"contexts":["rule-lint"],"checks":[{"context":"rule-lint","app_id":15368}]}'
export FAKE_BRANCH_PROTECTED=true FAKE_REQUIRED_STATUS_CHECKS="$PROT"
reset_cache; run_req
check_eq branch_protection "$(jq -r .source <<<"$OUT")" "cold: required list read live"
check_eq '["rule-lint"]' "$(jq -c .contexts <<<"$OUT")" "cold: contexts"
R_COLD="$OUT"
check_eq 1 "$(calls protection)" "cold: one protection read"
reset_calls; run_req
check_eq 0 "$(calls protection)" "warm: zero protection reads"
check_eq 0 "$(calls branch)" "warm: zero branch reads"
check_eq "$R_COLD" "$OUT" "warm: output byte-identical to the live run"
reset_calls; age_files 121; run_req
check_eq 1 "$(calls protection)" "entry older than the 120s maximum: live read"
reset_calls; FAKE_VIEWER=otheruser run_req
check_eq 1 "$(calls protection)" "different signed-in login: miss"
OUT=$(PATH="$BIN:$PATH" "$REQ" --repo solo/other --base main 2>/dev/null)
check_eq 2 "$(cache_files)" "a different repo gets its own entry, never solo/repo's"
f="$(find "$SLOW_READ_CACHE_DIR" -type f -name 'solo__repo__required-checks*' | head -1)"
printf '{"schema":1' > "$f"; reset_calls; run_req
check_eq 1 "$(calls protection)" "corrupt file: live read"
check_eq "$R_COLD" "$OUT" "corrupt file: right answer"

reset_calls; set_tip "$TIP_B"; run_req
check_eq 1 "$(calls protection)" "base moved: live read (the entry is keyed by the base tip)"
set_tip "$TIP_A"
reset_cache; FAKE_TIP_FAIL=1 run_req
check_eq branch_protection "$(jq -r .source <<<"$OUT")" "tip unreadable: live read, right answer"
check_eq 0 "$(cache_files)" "tip unreadable: nothing stored"
reset_cache; printf '%s\n%s\n' "$TIP_A" "$TIP_B" > "$TIPSEQ"; run_req
check_eq 0 "$(cache_files)" "base moved during the read: nothing stored"
set_tip "$TIP_A"

echo "== required checks: only a positive answer is ever stored"
reset_cache; FAKE_BRANCH_PROTECTED=false FAKE_REQUIRED_STATUS_CHECKS="" run_req
check_eq none "$(jq -r .source <<<"$OUT")" "unprotected base: source none"
check_eq 0 "$(cache_files)" "'none' is never stored"
reset_calls; run_req   # protection now exists (env back to PROT)
check_eq branch_protection "$(jq -r .source <<<"$OUT")" "protection added right after a 'none': seen immediately"
reset_cache
FAKE_BRANCH_JSON='{"message":"Server Error"}' FAKE_REQUIRED_STATUS_CHECKS="" run_req
check_eq unavailable "$(jq -r .source <<<"$OUT")" "unreadable: source unavailable"
check_eq 0 "$(cache_files)" "'unavailable' is never stored"

# ------------------------------------------------------------------ the library
echo "== lifetime clamps, file mode, no credentials"
. "$REPO_ROOT/.claude/scripts/lib/slow-read-cache.sh"
check_eq 300 "$(SLOW_READ_CACHE_TTL=99999 slow_cache_ttl codeowners)" "file reads: environment above the maximum -> 300"
check_eq 120 "$(SLOW_READ_CACHE_TTL=99999 slow_cache_ttl required-checks)" "settings: environment above the maximum -> 120"
check_eq 300 "$(SLOW_READ_CACHE_TTL=abc slow_cache_ttl pm-config)" "non-numeric -> maximum"
check_eq 120 "$(SLOW_READ_CACHE_TTL=-5 slow_cache_ttl required-checks)" "negative -> maximum"
check_eq 0 "$(SLOW_READ_CACHE_TTL=0 slow_cache_ttl codeowners)" "zero -> no caching"
check_eq 0 "$(slow_cache_ttl nonsense)" "unknown kind -> never cached"
reset_cache; SLOW_READ_CACHE_TTL=0 run_req
check_eq 0 "$(cache_files)" "TTL 0: nothing stored"
reset_cache; run_req
f="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*.json' | head -1)"
mode_of() { # BSD stat first; GNU stat only when BSD stat fails, never both outputs
  local m
  if m="$(stat -f '%Lp' "$1" 2>/dev/null)"; then printf '%s' "$m"; else stat -c '%a' "$1"; fi
}
check_eq 600 "$(mode_of "$f")" "entry mode 600"
check_eq 700 "$(mode_of "$(dirname "$f")")" "entry directory mode 700"
case "$f" in "$HOME/.claude/"*) ok "entries live under ~/.claude/" ;; *) bad "entry outside ~/.claude: $f" ;; esac
if grep -qiE 'token|authorization|bearer|ghp_|github_pat' "$f"; then bad "entry mentions a credential"; else ok "entry holds no credential"; fi
if grep -nE 'auth token|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|hosts\.yml' "$REPO_ROOT/.claude/scripts/lib/slow-read-cache.sh" >/dev/null; then
  bad "library handles credentials"; else ok "library has no credential handling"; fi
check_eq 1 "$(jq -r '.schema' "$f")" "entry carries its schema"
reset_cache; mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
R_OUT="$(SLOW_READ_CACHE_DIR="$TMP/ro/x" PATH="$BIN:$PATH" "$REQ" --repo solo/repo --base main 2>/dev/null)"; R_RC=$?
check_eq "$R_COLD" "$R_OUT" "unwritable cache directory: output unchanged"
check_eq 0 "$R_RC" "unwritable cache directory: exit code unchanged"
chmod 700 "$TMP/ro"

echo "----------------------------------------"
echo "slow-read-cache.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
