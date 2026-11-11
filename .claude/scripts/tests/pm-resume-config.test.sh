#!/usr/bin/env bash
# catalog: tests — Verifies portable PM resume config loading with the shared parser
# covers: .claude/skills/pm/modules/resume/load.md .claude/scripts/pm-config-get.sh
set -euo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$test_dir/../../.." && pwd)
source "$test_dir/lib/skill-bash.sh"
block=$(extract_skill_bash "$root/.claude/skills/pm/modules/resume/load.md" pm-resume-load-config)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pm-resume-config.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.claude" "$tmp/checkout/.claude"
cd "$tmp/checkout"
config=.claude/pm-config.md
parser="$root/.claude/scripts/pm-config-get.sh"

read_resume_config() {
  PM_CONFIG_GET="$1" "$BASH" -u -c "$block"
}
assert_result() {
  local expected="$1" actual="$2" label="$3"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok — %s\n' "$label"
}

cat > "$config" <<'CONFIG'
# PM config
## Project
project body
## Business Goal
first line

second line
## Empty
CONFIG
expected=$'LIST_RC=0\n## Project\nproject body\n## Business Goal\nfirst line\n\nsecond line\n## Empty'
assert_result "$expected" "$(read_resume_config "$parser")" 'spaced section and multiline body'

export TEST_REAL_PM_CONFIG_GET="$parser"
shim="$tmp/parser-with-fault"
cat > "$shim" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = --section ] && [ "$2" = 'Business Goal' ]; then exit 3; fi
exec "$TEST_REAL_PM_CONFIG_GET" "$@"
SHIM
chmod +x "$shim"
assert_result LIST_RC=3 "$(read_resume_config "$shim")" 'failed section read emits no partial config'
printf '%s\n' '# No sections' > "$config"
assert_result LIST_RC=1 "$(read_resume_config "$parser")" 'empty config has no section bodies'
mv "$config" "$tmp/no-sections"
assert_result LIST_RC=2 "$(read_resume_config "$parser")" 'missing config preserves the bootstrap status'
