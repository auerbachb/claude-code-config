#!/usr/bin/env bash
# Publisher/root-sync bounds, ample controls and deadline rejection cases.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-start-sync-fixtures.sh
source "$TEST_DIR/lib/session-start-sync-fixtures.sh"

# --- 15. The symlink publishers are BOUNDED (issue #1593) -------------------
# PR #1553 bounded the git region but deliberately left the publishers outside
# it, on the grounds that a few dozen readlink/ln/mv calls finish in well under
# a second. On a stalled network home they do not: an unbounded publisher
# outlives the registered 30s hook timeout mid-publish — some links rewritten,
# some not — and a KILL records nothing, so the marker-clear guard cannot see
# that the publish was partial and deletes a signal for definitions still stale
# on disk.
#
# Structural checks first, so a refactor that drops the bound fails loudly even
# where the functional fixture below cannot run.
grep -q '_HOOK_TAIL_RESERVE_SECS' "$HOOK" \
  || fail "session-start-sync.sh has no post-region reserve — the publishers and root-repo sync leg are not scheduled against the hook deadline (issue #1593)"
# The whole function body, not a fixed -A window: a comment added inside it
# must not silently push an assertion off the end and make it pass vacuously.
publish_one_body="$(awk '/^  _publish_one\(\) \{/,/^  \}$/' "$HOOK")"
[ -n "$publish_one_body" ] \
  || fail "could not extract the _publish_one body from session-start-sync.sh"
case "$publish_one_body" in
  *_run_hook_bounded*) : ;;
  *) fail "_publish_one runs its publisher unbounded — a stall outlives the 30s hook timeout with nothing recorded (issue #1593)" ;;
esac
case "$publish_one_body" in
  *'symlink publish failed: $(_bound_trip_reason)'*) : ;;
  *) fail "a publisher bound trip does not carry the '… symlink publish failed' token the publish guard keys off (issue #1593)" ;;
esac
case "$publish_one_body" in
  *_publish_incomplete=1*) : ;;
  *) fail "a publisher bound trip does not set _publish_incomplete — a partial publish could still clear the restart marker (issue #1593)" ;;
esac
# The root-repo sync leg (owner scope addition from PR #1553 BugBot 3922462913):
# it runs after the marker clear and before additionalContext is emitted, so an
# overrun there loses the session's informational notice.
[ "$(grep -c '_run_hook_bounded --reserve "\$_HOOK_TAIL_RESERVE_SECS" --context ' "$HOOK")" -eq 2 ] \
  || fail "session-start-sync.sh does not bound BOTH root-repo sync legs (main-sync.sh and the inline pull fallback) — issue #1593"
# ...and the decline message must not claim the lock is held: this leg runs
# AFTER the release, so a hard-coded lock rationale would be a false statement
# the reader cannot act on.
[ -z "$(grep '_run_hook_bounded --reserve "\$_HOOK_TAIL_RESERVE_SECS" --context ' "$HOOK" | grep 'holding the config-sync lock')" ] \
  || fail "the root-repo sync leg's decline message claims the config-sync lock is held, but the leg runs after the release (issue #1593)"

# ...and the bound those legs get must come from the SAME deadline the
# CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS override writes (CodeAnt, PR #1709). The
# tiny-deadline leg further down proves the override reaches the budget, but it
# can only ever watch the GIT legs decline: `_HOOK_GIT_RESERVE_SECS` (9) is
# larger than `_HOOK_TAIL_RESERVE_SECS` (3), so at any instant the post-region
# legs hold strictly MORE budget than the git region did — a deadline small
# enough to decline publishing declines the git work first, and the only way to
# invert that is to make the git region burn six-plus seconds of wall clock,
# which is the timing dependence this whole test exists to remove. So pin the
# last link of the chain STATICALLY instead: `_publish_one` runs through
# `_run_hook_bounded` (asserted above), `_run_hook_bounded` sizes itself from
# `_budget_remaining`, and `_budget_remaining` computes from
# `_HOOK_TIMEOUT_SECS`. A second budget source anywhere in that chain — a
# literal, a copied constant — would let the override reach the git legs and
# not the publishers, which is exactly the hole a dynamic assertion cannot see.
budget_remaining_body="$(awk '/^_budget_remaining\(\) \{/,/^\}$/' "$HOOK")"
[ -n "$budget_remaining_body" ] \
  || fail "could not extract the _budget_remaining body from session-start-sync.sh"
case "$budget_remaining_body" in
  *_HOOK_TIMEOUT_SECS*) : ;;
  *) fail "_budget_remaining no longer derives from _HOOK_TIMEOUT_SECS — the deadline override would stop reaching the bounded calls that read it (issue #1698)" ;;
esac
# Comment lines are stripped before matching: this function also MENTIONS
# _budget_remaining in a comment, so a bare substring check passes even after
# the call itself is replaced by a literal — the guard would hold by not
# running. Stripping can only ever remove a match, so the failure direction
# stays loud.
run_hook_bounded_body="$(awk '/^_run_hook_bounded\(\) \{/,/^\}$/' "$HOOK" \
  | sed 's/^[[:space:]]*#.*$//')"
[ -n "$run_hook_bounded_body" ] \
  || fail "could not extract the _run_hook_bounded body from session-start-sync.sh"
case "$run_hook_bounded_body" in
  *'_budget_remaining "'*) : ;;
  *) fail "_run_hook_bounded no longer sizes its bound by CALLING _budget_remaining — the publishers could be bounded against a deadline the CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS override does not reach (CodeAnt, PR #1709)" ;;
esac

# Functional fixture. The hook resolves its publishers from its OWN directory,
# so the stub has to live in a copied hook tree rather than in the temp HOME.
# Only the helpers the hook actually reaches are copied; register-hooks.py is
# stubbed so a registration error cannot masquerade as the publish failure
# under test (or, in the control below, block the marker clear).
build_publish_fixture() { # build_publish_fixture <root> <skill-publisher-body>
  local root="$1" body="$2"
  mkdir -p "$root/tree/.claude/hooks" "$root/tree/.claude/scripts/lib" "$root/home/.claude/logs"
  cp "$HOOK" "$root/tree/.claude/hooks/session-start-sync.sh"
  cp "$REPO_ROOT/.claude/scripts/state-lock.sh" "$REPO_ROOT/.claude/scripts/repo-root.sh" \
     "$root/tree/.claude/scripts/"
  cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$root/tree/.claude/scripts/lib/"
  printf '#!/usr/bin/env python3\nprint("hooks registered (stub)")\n' \
    > "$root/tree/.claude/hooks/register-hooks.py"
  printf '%s' "$body" > "$root/tree/.claude/scripts/publish-skill-symlinks.sh"
  printf '#!/bin/sh\nexit 0\n' > "$root/tree/.claude/scripts/publish-agent-symlinks.sh"
  chmod +x "$root/tree/.claude/scripts/publish-skill-symlinks.sh" \
           "$root/tree/.claude/scripts/publish-agent-symlinks.sh"
  # A real git worktree: the hook's bootstrap branch tests for a `.git` FILE,
  # which a clone does not have.
  # `git init -q` + symbolic-ref rather than `init -b`: -b needs git 2.28+, and
  # the sync suite's own fixture already uses this spelling.
  git init -q "$root/up"
  git -C "$root/up" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  mkdir -p "$root/up/.claude/skills/alpha"
  printf '# alpha\n' > "$root/up/.claude/skills/alpha/SKILL.md"
  git -C "$root/up" add -A >/dev/null 2>&1
  git -C "$root/up" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
  git clone -q "$root/up" "$root/base" >/dev/null 2>&1
  git -C "$root/base" worktree add -q --detach "$root/home/.claude/skills-worktree" main >/dev/null 2>&1
  cat > "$root/home/.claude/sync-restart-recommended.json" <<'JSON'
{
  "restart_recommended": {
    "reason": "config sync updated skills",
    "categories": ["skills"],
    "head_sha": "0123456789abcdef0123456789abcdef01234567",
    "at": "2026-09-01T00:00:00Z"
  }
}
JSON
}

P15="$(mktemp -d)"
ssync_register_tmp "$P15"

# Stalled leg: a publisher that sleeps far past its bound.
STALL="$P15/stall"
build_publish_fixture "$STALL" '#!/bin/sh
sleep 60
'
stall_started="$(date +%s)"
# No CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS here, deliberately: this leg runs on
# the production 30s deadline so the `< 45` elapsed check below stays a real
# assertion. Widening it here is what would make a genuinely stalling hook pass.
stall_out="$(printf '{"source":"startup"}' \
  | HOME="$STALL/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=2 \
    bash "$STALL/tree/.claude/hooks/session-start-sync.sh" 2>/dev/null || true)"
stall_elapsed=$(( $(date +%s) - stall_started ))

[ "$stall_elapsed" -lt 45 ] \
  || fail "a stalled publisher was not cut short — the hook ran ${stall_elapsed}s (issue #1593)"
STALL_OUT="$stall_out" python3 - <<'PY' || fail "a stalled publisher left no recorded failure; got: $stall_out"
import json, os, sys
text = os.environ.get("STALL_OUT", "").strip()
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
# The TOKEN is the contract — it is what the publish guard and the marker clear
# key off. The exact "2s" is not: the bound is min(budget left, ceiling), so a
# slow preamble legitimately shortens it, and on a very slow machine the call is
# DECLINED outright rather than exceeded. Asserting the literal 2s would turn
# either into a red suite for a fix that worked.
ok = "skill symlink publish failed" in ctx and ("exceeded its" in ctx or "declined:" in ctx)
sys.exit(0 if ok else 1)
PY
python3 - "$STALL/home/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup whose publisher tripped its bound cleared the restart marker — the session sits on a partial publish with no signal (issue #1593)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
sys.exit(0 if d.get("restart_recommended") is not None else 1)
PY

# Negative control: the SAME fixture with a publisher that finishes inside an
# ample bound. Without it the assertions above would pass for a hook that had
# simply stopped publishing altogether.
OKP="$P15/okp"
build_publish_fixture "$OKP" '#!/bin/sh
echo "  alpha — creating symlink"
exit 0
'
# The control's deadline is EXPLICIT and overridable (issue #1698). A 20s
# publish ceiling buys nothing on its own: every bound is
# min(budget left, ceiling), and `budget left` is what the hook has left of
# _HOOK_TIMEOUT_SECS after its own git work — so on a slow macOS runner the
# publish leg was declined for want of budget and the control failed with no
# code change (hook-tests-macos on PR #1689, contract from issue #1593). Only
# the CONTROL's headroom widens; the stall leg above keeps the production
# deadline.
# RAISE_OK is the hook's deliberate-widening pair: without it the hook refuses
# a deadline above its registered 30s and keeps 30 (CodeAnt, PR #1709), which
# would silently put this control back on the budget that made it flake.
okp_out="$(printf '{"source":"startup"}' \
  | HOME="$OKP/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=20 \
    CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS="$AMPLE_BUDGET_SECS" \
    CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_RAISE_OK=1 \
    bash "$OKP/tree/.claude/hooks/session-start-sync.sh" 2>/dev/null || true)"
# Silence must NOT read as success here (CodeAnt, PR #1640). Tolerating an
# empty body or a bare "{}" would let a hook that stopped emitting JSON — or
# never reached the publish block at all — satisfy the control that exists to
# prove the bound does not trip on a HEALTHY publisher. build_publish_fixture
# seeds a restart marker in this HOME precisely so the hook always has
# something to say, which makes "it said nothing" a real failure, not a
# tolerable no-op.
OKP_OUT="$okp_out" python3 - <<'PY' || fail "the ample-budget control did not produce a usable hook result, so it could not prove the bound leaves a healthy publisher alone; got: $okp_out"
import json, os, sys
text = os.environ.get("OKP_OUT", "").strip()
if not text or text == "{}":
    sys.exit(1)
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(1 if "publish failed" in ctx else 0)
PY
python3 - "$OKP/home/.claude/sync-restart-recommended.json" <<'PY' || fail "the ample-budget control did not clear the restart marker — the stall assertion above would pass vacuously (issue #1593)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
with open(path) as f:
    d = json.load(f)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
# Wiring proof for the knob the control leans on (issue #1698). The control
# above passes a widened deadline; if the hook ignored it, the control would
# still pass on a fast machine and go on flaking on a slow one — a knob that
# looks applied and does nothing. So drive the SAME healthy fixture with a
# deliberately tiny deadline: the budget cannot cover a single bounded call, so
# every one is declined and the marker must survive. Unlike a widened bound,
# this direction is not timing-sensitive — budget only ever shrinks with elapsed
# time, so a slow machine makes this leg MORE certain, never less.
TINY="$P15/tiny"
build_publish_fixture "$TINY" '#!/bin/sh
echo "  alpha — creating symlink"
exit 0
'
tiny_out="$(printf '{"source":"startup"}' \
  | HOME="$TINY/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=20 \
    CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS=1 \
    bash "$TINY/tree/.claude/hooks/session-start-sync.sh" 2>/dev/null || true)"
# "Some call was declined" is too weak an assertion to carry this (CodeAnt, PR
# #1709): a decline can come from an unrelated cause — bounded-run.sh missing,
# the capture handover failing — and would satisfy it while the override did
# nothing. The decline message names the deadline it measured against
# ("only Ns left of the Ms hook budget"), so require that M is OUR value. The
# default 30 cannot produce that string, which is what ties the pass to the knob.
#
# This leg watches the GIT legs decline and cannot be made to watch the PUBLISH
# leg instead (CodeAnt, PR #1709): the git region reserves 9s where the
# post-region legs reserve 3s, so publishing always holds strictly more budget
# than the git work that preceded it, and any deadline small enough to decline
# it declines the git region first. Naming "publish" here would be an assertion
# no deadline can satisfy. The publishers' half of the chain is pinned
# statically in the structural block above — _publish_one calls
# _run_hook_bounded, _run_hook_bounded calls _budget_remaining, and
# _budget_remaining computes from _HOOK_TIMEOUT_SECS — so a second budget
# source that reached the git legs but not the publishers fails there.
TINY_OUT="$tiny_out" python3 - <<'PY' || fail "a one-second hook deadline did not decline a bounded call AGAINST A 1s BUDGET — CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS is not reaching the budget, so the ample-budget control's widened deadline is a no-op (issue #1698); got: $tiny_out"
import json, os, sys
text = os.environ.get("TINY_OUT", "").strip()
if not text or text == "{}":
    sys.exit(1)
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(0 if "declined:" in ctx and "of the 1s hook budget" in ctx else 1)
PY
python3 - "$TINY/home/.claude/sync-restart-recommended.json" <<'PY' || fail "a one-second hook deadline cleared the restart marker despite declining its bounded calls (issue #1593, #1698)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    d = json.load(f)
sys.exit(0 if d.get("restart_recommended") is not None else 1)
PY

# The other half of the knob's contract: a raise WITHOUT its deliberate-widening
# pair is refused, not honoured (CodeAnt, PR #1709). The hazard is a stray
# exported CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS in a real session handing the
# hook a deadline longer than the `timeout: 30` it is registered with, at which
# point Claude kills it mid-git and nothing is recorded — the one outcome the
# deadline model exists to prevent. Refusing has to be VISIBLE too: a silent
# clamp would look identical to an honoured raise from inside a test, so the
# hook says which value it ignored and the assertion reads that sentence back.
NORAISE="$P15/noraise"
build_publish_fixture "$NORAISE" '#!/bin/sh
echo "  alpha — creating symlink"
exit 0
'
noraise_out="$(printf '{"source":"startup"}' \
  | HOME="$NORAISE/home" CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS=120 \
    bash "$NORAISE/tree/.claude/hooks/session-start-sync.sh" 2>/dev/null || true)"
NORAISE_OUT="$noraise_out" python3 - <<'PY' || fail "a 120s deadline was accepted without CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_RAISE_OK, or was clamped silently — an inherited override must neither outlive the registered 30s hook timeout nor do so without saying it did (CodeAnt, PR #1709); got: $noraise_out"
import json, os, sys
text = os.environ.get("NORAISE_OUT", "").strip()
if not text or text == "{}":
    sys.exit(1)
try:
    ctx = json.loads(text)["hookSpecificOutput"]["additionalContext"]
except Exception:
    sys.exit(1)
sys.exit(0 if "ignored CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS=120" in ctx else 1)
PY

# A tripped publisher still owes the RESUME-path restart signal (CodeAnt, PR
# #1640). The two assertions above cover the startup path, where the trip is
# recorded and the marker is merely left alone. On a resume the marker is not
# read-only: leg 3 WRITES the categories whose links a publisher repointed, and
# it is the only thing that ever reports a repoint under an unchanged HEAD — a
# later scheduled tick sees a stable HEAD and the links already in place. A trip
# cuts the publisher after an unknown subset of its links landed, so the hook
# must claim that publisher's whole category set rather than harvest a killed
# child's block-buffered stdout, which can be empty precisely when links did
# change. The fixture seeds a marker holding only "skills", so claude-md and
# rules appearing proves the claim ran rather than the seed being echoed back.
STALLR="$P15/stallr"
build_publish_fixture "$STALLR" '#!/bin/sh
sleep 60
'
printf '{"source":"resume"}' \
  | HOME="$STALLR/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=2 \
    bash "$STALLR/tree/.claude/hooks/session-start-sync.sh" >/dev/null 2>&1 || true
python3 - "$STALLR/home/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume whose skill publisher tripped its bound did not record that publisher's categories — links it repointed before the kill are forever-silent (CodeAnt, PR #1640)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(1)
with open(path) as f:
    cats = json.load(f).get("restart_recommended", {}).get("categories") or []
sys.exit(0 if {"claude-md", "rules"} <= set(cats) else 1)
PY

# Negative control for the claim: a HEALTHY publisher on the same resume path
# must NOT claim categories it never touched. Without this, the assertion above
# would pass for a hook that unconditionally claimed every category on every
# run, which would make the restart signal meaningless rather than honest.
OKPR="$P15/okpr"
build_publish_fixture "$OKPR" '#!/bin/sh
echo "  alpha — creating symlink"
exit 0
'
printf '{"source":"resume"}' \
  | HOME="$OKPR/home" CLAUDE_CONFIG_SYNC_HOOK_PUBLISH_BOUND=20 \
    bash "$OKPR/tree/.claude/hooks/session-start-sync.sh" >/dev/null 2>&1 || true
python3 - "$OKPR/home/.claude/sync-restart-recommended.json" <<'PY' || fail "a healthy resume publisher claimed claude-md/rules it never printed — the trip claim is firing unconditionally (CodeAnt, PR #1640)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
with open(path) as f:
    cats = json.load(f).get("restart_recommended", {}).get("categories") or []
sys.exit(1 if {"claude-md", "rules"} & set(cats) else 0)
PY
rm -rf "$P15"

echo "OK: session-start-sync publisher bound tests passed"
