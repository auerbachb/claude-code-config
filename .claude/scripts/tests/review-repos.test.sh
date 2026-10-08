#!/usr/bin/env bash
# Tests for .claude/scripts/review-repos.sh (issue #1808).
# catalog: tests — Tests `review-repos.sh` offline — `REVIEW_REPOS` env, the account config's explicit list, `--fixture` discovery (archived/no-marker/foreign-owner filtering), fail-closed discovery and malformed entries, and that the shipped `.claude/account-config.md` resolves
#
# Every case is OFFLINE: discovery is driven through --fixture, which runs the
# same jq filter the live GraphQL response goes through. HOME is sandboxed so
# the telemetry append and the default ~/.claude/account-config.md lookup never
# touch the developer's real ~/.claude; CLAUDE_ACCOUNT_CONFIG is set per case.
#
# The property under test throughout is "never a partial list": every failure
# case asserts exit 1 AND empty stdout, because a caller (measure.sh
# --all-repos) that got half a list would measure half the account and report
# it as the whole.
#
# Usage: bash .claude/scripts/tests/review-repos.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/review-repos.sh"
SHIPPED_CONFIG="$REPO_ROOT/.claude/account-config.md"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
export HOME="$TMP_DIR/home"
mkdir -p "$HOME/.claude"
unset REVIEW_REPOS CLAUDE_ACCOUNT_CONFIG

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok() { echo "ok   — $*"; }

[[ -x "$SCRIPT" ]] || { echo "FAIL: review-repos.sh missing or not executable" >&2; exit 1; }

NO_CONFIG="$TMP_DIR/no-such-config.md"
OUT="$TMP_DIR/out"
ERR="$TMP_DIR/err"

# run [env assignments...] -- [args...] : stdout -> $OUT, stderr -> $ERR, rc -> $RC
run() {
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  env ${envs[@]+"${envs[@]}"} "$SCRIPT" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

expect_list() { # expect_list <label> <expected, newline-joined>
  local label="$1" want="$2"
  if [[ $RC -eq 0 && "$(cat "$OUT")" == "$want" ]]; then
    ok "$label"
  else
    fail "$label (rc=$RC, got: $(tr '\n' ' ' < "$OUT"), stderr: $(head -c 200 "$ERR"))"
  fi
}

expect_fail_closed() { # expect_fail_closed <label>
  local label="$1"
  if [[ $RC -eq 1 && ! -s "$OUT" && -s "$ERR" ]]; then
    ok "$label"
  else
    fail "$label (want rc=1, empty stdout, a stderr reason; got rc=$RC, stdout: $(tr '\n' ' ' < "$OUT"))"
  fi
}

# A GraphQL page in the shape discovery requests.
page() { # page <nodes-json>
  printf '{"data":{"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}}}' "$1"
}

# ---------------------------------------------------------------------------
# Contract surface
# ---------------------------------------------------------------------------

run -- --help
[[ $RC -eq 0 && -s "$OUT" && ! -s "$ERR" ]] && grep -q 'RESOLUTION ORDER' "$OUT" \
  && ok "--help exits 0 and documents the resolution order" \
  || fail "--help contract broken (rc=$RC)"
run -- --bogus
[[ $RC -eq 2 ]] && ok "unknown flag is a usage error (exit 2)" || fail "unknown flag should exit 2, got $RC"
run -- --fixture
[[ $RC -eq 2 ]] && ok "--fixture without a value is a usage error" || fail "--fixture without value should exit 2, got $RC"

# ---------------------------------------------------------------------------
# 1. REVIEW_REPOS env
# ---------------------------------------------------------------------------

run "REVIEW_REPOS=a/b,c/d" "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" --
expect_list "env: REVIEW_REPOS=a/b,c/d returns exactly those two" $'a/b\nc/d'

run "REVIEW_REPOS= a/b  c/d,,A/B " "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" --
expect_list "env: commas and whitespace both separate; duplicates fold case-insensitively" $'a/b\nc/d'

run "REVIEW_REPOS=a/b,not-a-repo" "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" --
expect_fail_closed "env: one malformed entry fails the whole list (no partial a/b)"

# Every entry ends up in a `gh api repos/<owner>/<name>/...` path, so a dot
# segment must never pass as a repo name. `.github` is a real repo name and must.
for bad in "acme/.." "acme/." "../acme" ".hidden/repo"; do
  run "REVIEW_REPOS=$bad" "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" --
  expect_fail_closed "env: '$bad' is refused (dot segment or dotted owner)"
done
run "REVIEW_REPOS=acme/.github,acme/my.repo_x-1" "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" --
expect_list "env: real names with dots, underscores and hyphens still pass" $'acme/.github\nacme/my.repo_x-1'

# ---------------------------------------------------------------------------
# 2. The account config's explicit list
# ---------------------------------------------------------------------------

CONFIG="$TMP_DIR/account-config.md"
cat > "$CONFIG" <<'MD'
# Account Config

## Something else

- not/this-one

## Review repos

<!-- notes live in comments and plain lines; every bullet is an entry -->
A plain prose line is ignored.

```ini
owner = acme
discovery_marker = ac-gate.yml
```

- `acme/alpha` — backticks are stripped
- acme/beta

## After

- not/this-either
MD

run "CLAUDE_ACCOUNT_CONFIG=$CONFIG" --
expect_list "config: with no env, the section's explicit list is returned" $'acme/alpha\nacme/beta'

run "REVIEW_REPOS=x/y" "CLAUDE_ACCOUNT_CONFIG=$CONFIG" --
expect_list "config: REVIEW_REPOS still wins over the config list" 'x/y'

# The default path is ~/.claude/account-config.md — the published symlink.
cp "$CONFIG" "$HOME/.claude/account-config.md"
run --
expect_list "config: the default path is ~/.claude/account-config.md" $'acme/alpha\nacme/beta'
rm -f "$HOME/.claude/account-config.md"

BAD_CONFIG="$TMP_DIR/bad-config.md"
printf '## Review repos\n\n- acme/ok\n- acme/bad:name\n' > "$BAD_CONFIG"
run "CLAUDE_ACCOUNT_CONFIG=$BAD_CONFIG" --
expect_fail_closed "config: a malformed list entry fails the whole list"

# A bullet missing its slash is a typo, not prose: it must fail the list rather
# than be skipped, or `- acme-sales-kit` would silently leave a repo unmeasured.
printf '## Review repos\n\n- acme/ok\n- acme-sales-kit\n' > "$BAD_CONFIG"
run "CLAUDE_ACCOUNT_CONFIG=$BAD_CONFIG" --
expect_fail_closed "config: a slash-less bullet fails the list instead of being skipped"

# A bullet inside an HTML comment is a note, not an entry — on one line or
# spanning several, and whether or not it is a well-formed owner/name (a
# malformed one would otherwise fail the list, a well-formed one would add an
# unreviewed repo). Text either side of a comment on the same line survives.
COMMENTED="$TMP_DIR/commented-config.md"
cat > "$COMMENTED" <<'MD'
## Review repos

<!-- - acme/retired -->
<!--
- acme/also-retired
- not-a-repo
-->
- acme/alpha <!-- kept: the comment is trailing -->
- <!-- leading comment --> acme/beta
MD
run "CLAUDE_ACCOUNT_CONFIG=$COMMENTED" --
expect_list "config: bullets inside HTML comments are notes, not entries" $'acme/alpha\nacme/beta'

mkdir -p "$TMP_DIR/config-is-a-dir"
run "CLAUDE_ACCOUNT_CONFIG=$TMP_DIR/config-is-a-dir" --
expect_fail_closed "config: a config path that is not a readable file fails rather than falling to discovery"

# ---------------------------------------------------------------------------
# 3. Discovery (--fixture stands in for the GraphQL response)
# ---------------------------------------------------------------------------

DISC="$TMP_DIR/discovery.json"
page '[
  {"nameWithOwner":"acme/live","isArchived":false,"object":{"id":"x"}},
  {"nameWithOwner":"acme/no-marker","isArchived":false,"object":null},
  {"nameWithOwner":"acme/archived","isArchived":true,"object":{"id":"x"}},
  {"nameWithOwner":"other/collab","isArchived":false,"object":{"id":"x"}}]' > "$DISC"
# A second page, concatenated exactly as `gh api --paginate` emits it.
page '[{"nameWithOwner":"acme/page-two","isArchived":false,"object":{"id":"x"}}]' >> "$DISC"

run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$DISC"
expect_list "discovery: --fixture returns the marker-carrying, non-archived repos across pages" \
  $'acme/live\nother/collab\nacme/page-two'

# With an owner configured (and no list), collaborator repos are dropped: the
# RepositoryOwner connection returns them, and they are not ours to bill.
OWNER_ONLY="$TMP_DIR/owner-only.md"
printf '## Review repos\n\nowner = acme\n' > "$OWNER_ONLY"
run "CLAUDE_ACCOUNT_CONFIG=$OWNER_ONLY" -- --fixture "$DISC"
expect_list "discovery: a configured owner filters out repos it does not own" \
  $'acme/live\nacme/page-two'

# Steps 1 and 2 still win when they resolve; the fixture feeds step 3 only.
run "CLAUDE_ACCOUNT_CONFIG=$CONFIG" -- --fixture "$DISC"
expect_list "discovery: an explicit config list is used even when --fixture is given" $'acme/alpha\nacme/beta'

printf '{"data":{"repositoryOwner":null}}' > "$TMP_DIR/unknown-owner.json"
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$TMP_DIR/unknown-owner.json"
expect_fail_closed "discovery: an unknown owner is a failure, not an empty list"

# A good page followed by an error envelope must not yield the good page's repos.
{ page '[{"nameWithOwner":"acme/live","isArchived":false,"object":{"id":"x"}}]'
  printf '{"errors":[{"message":"rate limited"}]}'; } > "$TMP_DIR/partial.json"
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$TMP_DIR/partial.json"
expect_fail_closed "discovery: an error on a later page discards the earlier pages (no partial list)"

# GraphQL's partial-result shape: `data` AND `errors` on the same page. The
# nodes it did return are well-formed, so only the errors check refuses it.
printf '{"data":{"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"nameWithOwner":"acme/live","isArchived":false,"object":{"id":"x"}}]}}},"errors":[{"message":"Something went wrong"}]}' \
  > "$TMP_DIR/data-and-errors.json"
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$TMP_DIR/data-and-errors.json"
expect_fail_closed "discovery: a page with errors beside its data is refused (partial result)"

printf '{not json' > "$TMP_DIR/garbage.json"
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$TMP_DIR/garbage.json"
expect_fail_closed "discovery: an unparseable response exits 1"

page '[{"nameWithOwner":"acme/no-marker","isArchived":false,"object":null}]' > "$TMP_DIR/none.json"
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$TMP_DIR/none.json"
expect_fail_closed "discovery: finding no repo is a failure, never an empty success"

run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --fixture "$TMP_DIR/does-not-exist.json"
expect_fail_closed "discovery: an unreadable fixture exits 1"

BAD_MARKER="$TMP_DIR/bad-marker.md"
printf '## Review repos\n\ndiscovery_marker = ../../secrets.yml\n' > "$BAD_MARKER"
run "CLAUDE_ACCOUNT_CONFIG=$BAD_MARKER" -- --fixture "$DISC"
expect_fail_closed "discovery: a marker that is a path, not a workflow file name, is refused"

# --no-discovery: steps 1 and 2 only. gh is replaced by a stub that records any
# call, so the failure case proves discovery never ran rather than that it ran
# and failed.
mkdir -p "$TMP_DIR/gh-trap"
printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$TMP_DIR/gh-trap/calls" > "$TMP_DIR/gh-trap/gh"
chmod +x "$TMP_DIR/gh-trap/gh"
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" "PATH=$TMP_DIR/gh-trap:$PATH" -- --no-discovery
if [[ $RC -eq 1 && ! -s "$OUT" && ! -e "$TMP_DIR/gh-trap/calls" ]]; then
  ok "--no-discovery: nothing registered exits 1 without calling gh"
else
  fail "--no-discovery: want rc=1, empty stdout, no gh call (rc=$RC)"
fi
# Control: the same run WITHOUT the flag does reach the stub, so the assertion
# above is about --no-discovery and not about a trap that could never fire.
run "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" "PATH=$TMP_DIR/gh-trap:$PATH" --
[[ $RC -eq 1 && -e "$TMP_DIR/gh-trap/calls" ]] \
  && ok "--no-discovery control: without the flag, discovery does call gh" \
  || fail "--no-discovery control: the gh stub was never reached (rc=$RC) — the trap proves nothing"
run "REVIEW_REPOS=a/b" "CLAUDE_ACCOUNT_CONFIG=$NO_CONFIG" -- --no-discovery
expect_list "--no-discovery: REVIEW_REPOS still resolves" 'a/b'
run "CLAUDE_ACCOUNT_CONFIG=$CONFIG" -- --no-discovery
expect_list "--no-discovery: the config list still resolves" $'acme/alpha\nacme/beta'
run -- --no-discovery --fixture "$DISC"
[[ $RC -eq 2 ]] && ok "--no-discovery with --fixture is a usage error" \
  || fail "--no-discovery with --fixture should exit 2, got $RC"

# ---------------------------------------------------------------------------
# The shipped account config
# ---------------------------------------------------------------------------

if [[ -r "$SHIPPED_CONFIG" ]]; then
  run "CLAUDE_ACCOUNT_CONFIG=$SHIPPED_CONFIG" --
  if [[ $RC -eq 0 ]] && grep -qx 'auerbachb/claude-code-config' "$OUT" \
     && ! grep -qvE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' "$OUT"; then
    ok "shipped: .claude/account-config.md resolves to an explicit list including this repo"
  else
    fail "shipped: .claude/account-config.md did not resolve (rc=$RC: $(head -c 200 "$ERR"))"
  fi
  grep -qE '^[[:space:]]*owner[[:space:]]*=[[:space:]]*auerbachb[[:space:]]*$' "$SHIPPED_CONFIG" \
    && grep -qE '^[[:space:]]*discovery_marker[[:space:]]*=[[:space:]]*ac-gate\.yml[[:space:]]*$' "$SHIPPED_CONFIG" \
    && ok "shipped: the section records owner = auerbachb and the ac-gate.yml discovery marker" \
    || fail "shipped: owner / discovery_marker lines missing from $SHIPPED_CONFIG"
else
  fail "shipped: $SHIPPED_CONFIG is missing"
fi

[[ $FAILED -eq 0 ]] && echo "All review-repos tests passed."
exit $FAILED
