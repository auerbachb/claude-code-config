#!/usr/bin/env bash
# catalog: tests — Verifies the /pm bootstrap publish never replaces a config that appears after the absence probe
# covers: .claude/skills/pm/modules/shared/config.md .claude/skills/pm/modules/rank/load.md .claude/scripts/tests/lib/skill-bash.sh
set -uo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$test_dir/../../.." && pwd)
source "$test_dir/lib/skill-bash.sh"
module="$root/.claude/skills/pm/modules/shared/config.md"
block=$(extract_skill_bash "$module" pm-config-bootstrap-publish) || exit 1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pm-config-bootstrap.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/checkout/.claude" || exit 1
cd "$tmp/checkout" || exit 1
dest=.claude/pm-config.md
fails=0

check() { # label, status (0 = pass)
  if [ "$2" -eq 0 ]; then
    printf 'ok — %s\n' "$1"
  else
    printf 'FAIL: %s\n' "$1" >&2
    fails=$((fails + 1))
  fi
}
reset_checkout() {
  rm -rf .claude
  mkdir -p .claude
}
stage_file() {
  STAGE=$(mktemp "$dest.bootstrap.XXXXXX")
  chmod 0644 "$STAGE"
  printf 'template body\n' > "$STAGE"
}
publish() {
  OUT=$(CONFIG_FILE="$dest" BOOTSTRAP_STAGE="$STAGE" "$BASH" -u -c "$block" 2>"$tmp/err")
  RC=$?
}
no_stage_left() {
  [ -z "$(ls .claude/ | grep 'pm-config.md.bootstrap' || true)" ]
}

# Fresh
reset_checkout
stage_file
publish
[ "$OUT" = "BOOTSTRAP_PUBLISH=created" ]; check 'fresh: created' $?
[ "$(cat "$dest")" = 'template body' ]; check 'fresh: bytes match stage' $?
if mode=$(stat -c %a "$dest" 2>/dev/null); then :; else mode=$(stat -f %Lp "$dest"); fi
[ "$mode" = 644 ]; check 'fresh: mode 0644' $?
no_stage_left; check 'fresh: no stage left' $?

# Race: winner appears after staging
reset_checkout
stage_file
printf 'winner edits\n' > "$dest"
publish
[ "$OUT" = "BOOTSTRAP_PUBLISH=existing" ]; check 'race: existing' $?
[ "$(cat "$dest")" = 'winner edits' ]; check 'race: winner bytes unchanged' $?
no_stage_left; check 'race: no stage left' $?

# Directory destination
reset_checkout
mkdir -p "$dest"
stage_file
publish
[ "$OUT" = "BOOTSTRAP_PUBLISH=existing" ]; check 'directory: existing' $?
[ -z "$(ls -A "$dest")" ]; check 'directory: no nested link' $?

# Dangling symlink
reset_checkout
ln -s "$tmp/nowhere" "$dest"
stage_file
publish
[ "$OUT" = "BOOTSTRAP_PUBLISH=existing" ]; check 'dangling symlink: existing' $?
[ "$(readlink "$dest")" = "$tmp/nowhere" ] && [ ! -e "$tmp/nowhere" ]; check 'dangling symlink: target unchanged' $?

# Non-conflict OSError (python3 shim)
reset_checkout
mkdir -p "$tmp/shim"
stage_file
cat > "$tmp/shim/python3" <<'SHIM'
#!/bin/sh
echo "simulated I/O failure" >&2
exit 11
SHIM
chmod +x "$tmp/shim/python3"
OUT=$(PATH="$tmp/shim:$PATH" CONFIG_FILE="$dest" BOOTSTRAP_STAGE="$STAGE" "$BASH" -u -c "$block" 2>"$tmp/err")
RC=$?
[ "$OUT" = "BOOTSTRAP_PUBLISH=error" ] && [ "$RC" -ne 0 ]; check 'os error: error outcome' $?
grep -q 'simulated I/O failure' "$tmp/err"; check 'os error: real error text kept' $?
[ ! -e "$dest" ]; check 'os error: destination not created' $?
no_stage_left; check 'os error: no stage left' $?

# Missing python3
reset_checkout
mkdir -p "$tmp/nopy"
ln -sf "$(command -v rm)" "$tmp/nopy/rm"
stage_file
OUT=$(PATH="$tmp/nopy" CONFIG_FILE="$dest" BOOTSTRAP_STAGE="$STAGE" "$BASH" -u -c "$block" 2>"$tmp/err")
RC=$?
[ "$OUT" = "BOOTSTRAP_PUBLISH=error" ] && [ "$RC" -ne 0 ]; check 'no python3: error outcome' $?
[ ! -e "$dest" ]; check 'no python3: destination not created' $?
no_stage_left; check 'no python3: no stage left' $?

# Unset stage input
OUT=$(CONFIG_FILE="$dest" BOOTSTRAP_STAGE= "$BASH" -u -c "$block" 2>/dev/null)
[ "$OUT" = "BOOTSTRAP_PUBLISH=error" ]; check 'unset stage: error outcome' $?

# Static: probe checks -L
grep -q '! -L "\$CONFIG_FILE"' "$module"; check 'probe contains the -L check' $?

if [ "$fails" -ne 0 ]; then
  printf '%s check(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'all checks passed\n'
