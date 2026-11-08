#!/usr/bin/env bash
# Resume-source fast-forward and publisher category signals.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-start-sync-fixtures.sh
source "$TEST_DIR/lib/session-start-sync-fixtures.sh"

# --- 14. resume-source fast-forward writes the restart signal (BugBot High, PR #1553) ---
# A resumed session keeps the definitions it loaded at its original start. When
# the hook's own fast-forward brings in new content on resume/compact/clear,
# nothing else will ever signal it: the scheduled job only reports changes its
# own run made, and its next tick sees an unchanged HEAD. The hook must write
# restart_recommended itself — and a startup control must NOT trip this path.
R14="$(mktemp -d)"
ssync_register_tmp "$R14"
R14_HOME="$R14/home"; mkdir -p "$R14_HOME/.claude/logs"
R14_UP="$R14/upstream"
git init -q -b main "$R14_UP"
mkdir -p "$R14_UP/.claude/skills/alpha"
printf '# one\n' > "$R14_UP/.claude/skills/alpha/SKILL.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm one
# A real skills-worktree is a `git worktree` (its .git is a FILE); a plain clone
# has a .git DIRECTORY and trips the hook's bootstrap branch instead.
git clone -q "$R14_UP" "$R14/base"
git -C "$R14/base" worktree add -q --detach "$R14_HOME/.claude/skills-worktree" main
printf '# two\n' > "$R14_UP/.claude/skills/alpha/SKILL.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm two
printf '{"source":"resume"}' | HOME="$R14_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume-source fast-forward left no restart signal — the resumed session runs stale definitions with no reminder (BugBot High, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "skills" in (rr.get("categories") or []) else 1)
PY
# Control: the same fast-forward on a STARTUP source must not leave a restart
# signal — a fresh session already loaded what it just fetched.
R14B_HOME="$R14/home-b"; mkdir -p "$R14B_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-b"
git -C "$R14/base-b" worktree add -q --detach "$R14B_HOME/.claude/skills-worktree" main
git -C "$R14B_HOME/.claude/skills-worktree" reset -q --hard HEAD~1
printf '{"source":"startup"}' | HOME="$R14B_HOME" bash "$HOOK" >/dev/null 2>&1 || true
# The control is only a control if the startup actually fast-forwarded: a
# failed fetch would leave the marker absent for the wrong reason.
[ "$(git -C "$R14B_HOME/.claude/skills-worktree" rev-parse HEAD)" = "$(git -C "$R14_UP" rev-parse main)" ] \
  || fail "the startup control did not fast-forward — its no-signal result would be vacuous"
python3 - "$R14B_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a startup-source fast-forward wrote a restart signal — a fresh session already loaded what it fetched"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
# Link-only leg: a resume whose publish CREATED links with an unchanged HEAD is
# just as forever-silent (a later tick sees a stable HEAD and the links already
# in place), so it must write the signal too.
R14C_HOME="$R14/home-c"; mkdir -p "$R14C_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-c"
git -C "$R14/base-c" worktree add -q --detach "$R14C_HOME/.claude/skills-worktree" main
printf '{"source":"resume"}' | HOME="$R14C_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14C_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume whose publish created links on an unchanged HEAD left no restart signal (BugBot Medium, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "skills" in (rr.get("categories") or []) else 1)
PY
# Phantom control: a user-owned AGENT link makes the agents publisher print its
# standing advisory on stdout. With links already settled and nothing changed,
# a resume must NOT raise a restart signal off that advisory.
printf '# beta agent\n' > "$R14_UP/.claude/agents-placeholder" 2>/dev/null || true
mkdir -p "$R14_UP/.claude/agents"
printf '# beta\n' > "$R14_UP/.claude/agents/beta.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm three
R14D_HOME="$R14/home-d"; mkdir -p "$R14D_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-d"
git -C "$R14/base-d" worktree add -q --detach "$R14D_HOME/.claude/skills-worktree" main
# First run (startup) settles every link and writes no signal by design.
printf '{"source":"startup"}' | HOME="$R14D_HOME" bash "$HOOK" >/dev/null 2>&1 || true
# Plant a personal agent link, then resume with nothing else changed.
mkdir -p "$R14D_HOME/.claude/agents"
ln -sf /tmp/does-not-matter "$R14D_HOME/.claude/agents/gamma.md" 2>/dev/null || true
printf '{"source":"resume"}' | HOME="$R14D_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14D_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a settled resume with only a user-owned agent link raised a phantom restart signal (BugBot d377f4b1, PR #1553)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
# Error-independence leg: a resume whose FETCH fails but whose publish still
# lands link changes must still write the signal — a later unrelated error must
# not suppress work that already landed (the scheduled job can never recover
# it: its next tick sees a stable HEAD and the links already in place).
R14E_HOME="$R14/home-e"; mkdir -p "$R14E_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-e"
git -C "$R14/base-e" worktree add -q --detach "$R14E_HOME/.claude/skills-worktree" main
git -C "$R14E_HOME/.claude/skills-worktree" remote set-url origin "$R14/nonexistent-upstream"
printf '{"source":"resume"}' | HOME="$R14E_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14E_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume with a failed fetch but a landed publish left no restart signal — a later unrelated error suppressed landed work (BugBot High, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "skills" in (rr.get("categories") or []) else 1)
PY
# CLAUDE.md label mapping: a resume that links CLAUDE.md must record claude-md,
# not blanket-'skills' — the two marker writers must agree on category names.
printf '# global claude md\n' > "$R14_UP/CLAUDE.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm four
R14F_HOME="$R14/home-f"; mkdir -p "$R14F_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-f"
git -C "$R14/base-f" worktree add -q --detach "$R14F_HOME/.claude/skills-worktree" main
printf '{"source":"resume"}' | HOME="$R14F_HOME" bash "$HOOK" >/dev/null 2>&1 || true
python3 - "$R14F_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume that linked CLAUDE.md did not record the claude-md category (BugBot 7454568b, PR #1553)"
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
rr = d.get("restart_recommended") or {}
sys.exit(0 if "claude-md" in (rr.get("categories") or []) else 1)
PY
# account-config.md maps to NO category (issue #1808): it is data review-repos.sh
# reads on every run, so (re)creating its link on an unchanged HEAD must not
# raise a restart signal — the skill publisher prints that line too, and an
# unlabelled change line used to be filed under "skills". Settle every link on
# startup, drop only the account-config.md link, then resume.
mkdir -p "$R14_UP/.claude"
printf '# account config\n' > "$R14_UP/.claude/account-config.md"
git -C "$R14_UP" add -A >/dev/null 2>&1
git -C "$R14_UP" -c user.email=t@t -c user.name=t commit -qm five
R14G_HOME="$R14/home-g"; mkdir -p "$R14G_HOME/.claude/logs"
git clone -q "$R14_UP" "$R14/base-g"
git -C "$R14/base-g" worktree add -q --detach "$R14G_HOME/.claude/skills-worktree" main
printf '{"source":"startup"}' | HOME="$R14G_HOME" bash "$HOOK" >/dev/null 2>&1 || true
[ -L "$R14G_HOME/.claude/account-config.md" ] \
  || fail "fixture: startup did not publish the account-config.md link — the resume check below would be vacuous"
rm -f "$R14G_HOME/.claude/account-config.md"
printf '{"source":"resume"}' | HOME="$R14G_HOME" bash "$HOOK" >/dev/null 2>&1 || true
[ -L "$R14G_HOME/.claude/account-config.md" ] \
  || fail "fixture: the resume did not recreate the account-config.md link — its no-signal result would be vacuous"
python3 - "$R14G_HOME/.claude/sync-restart-recommended.json" <<'PY' || fail "a resume that only recreated the account-config.md link raised a restart signal — data-only config was filed as a skills change (CodeAnt, PR #1817)"
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
sys.exit(1 if d.get("restart_recommended") is not None else 0)
PY
# Harvest-before-rc ordering: the category harvest must precede the non-zero
# exit branch, or a publisher that lands links then fails hides them. The bound
# trip is the ONE branch that legitimately precedes the harvest: a killed
# publisher's capture is not a trustworthy account of what it landed, and it is
# recorded as incomplete rather than harvested.
harvest_line="$(grep -n '_publish_change_verbs" <<< "\$out"' "$HOOK" | head -1 | cut -d: -f1)"
rcbranch_line="$(grep -n 'symlink publish failed: \${err:-\$out}' "$HOOK" | head -1 | cut -d: -f1)"
[ -n "$harvest_line" ] && [ -n "$rcbranch_line" ] \
  || fail "could not locate the harvest / rc-branch lines in _publish_one"
[ "$harvest_line" -lt "$rcbranch_line" ] \
  || fail "_publish_one branches on rc before harvesting change categories — landed links from a failing publisher are hidden (BugBot, PR #1553)"
rm -rf "$R14"

echo "OK: session-start-sync resume tests passed"
