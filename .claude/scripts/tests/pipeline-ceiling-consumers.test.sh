#!/usr/bin/env bash
# Regression coverage for Issue #1729: the pipeline ceiling is a per-repo knob.
# catalog: tests — Static check that `/subagent`, `/pm`, `/wave`, and `/pm-forgotten-pr`'s merge dispatch read the pipeline ceiling from `active-work-cap.sh --ceiling` instead of a literal
#
# The three original consumers used to hard-code the 3–4 band (`CEILING = 4` in
# /wave, "3–4 concurrent pipelines" in /subagent and /pm), so widening one repo
# meant a global rule edit. They now resolve PIPELINE_CEILING through
# `active-work-cap.sh --ceiling`, and so does the fourth consumer,
# /pm-forgotten-pr's merge dispatch. This suite fails if any of them stops
# resolving it, or if a literal ceiling creeps back into slot math.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok   — %s\n' "$*"; }

require_text() {
  local file=$1 text=$2 message=$3
  grep -Fq -- "$text" "$ROOT/$file" || fail "$message"
}

reject_pattern() {
  local file=$1 pattern=$2 message=$3 hit
  # A missing file would make grep fail and read as "no match" — fail closed.
  [[ -r "$ROOT/$file" ]] || fail "cannot read $file"
  if hit=$(grep -En -- "$pattern" "$ROOT/$file"); then
    fail "$message: $hit"
  fi
}

SUBAGENT=.claude/skills/subagent/SKILL.md
PM=.claude/skills/pm/SKILL.md
WAVE=.claude/skills/wave/SKILL.md
FORGOTTEN=.claude/skills/pm-forgotten-pr/SKILL.md

# --- each consumer resolves the ceiling from the script ---------------------
require_text "$SUBAGENT" 'ACTIVE_WORK_CAP_SH=$(resolve_script active-work-cap.sh' \
  '/subagent must resolve active-work-cap.sh (Step 0 helper block)'
require_text "$SUBAGENT" 'CEILING=$("$ACTIVE_WORK_CAP_SH" --ceiling)' \
  '/subagent Step 7 must read the ceiling via active-work-cap.sh --ceiling'
require_text "$PM" 'CEILING=$("$ACTIVE_WORK_CAP_SH" --ceiling)' \
  '/pm Step 0 must read the ceiling via active-work-cap.sh --ceiling'
require_text "$WAVE" 'CEILING    = "$ACTIVE_WORK_CAP_SH" --ceiling' \
  '/wave Step 6 must read CEILING via active-work-cap.sh --ceiling'
require_text "$FORGOTTEN" '"$(resolve_script active-work-cap.sh)" --ceiling' \
  '/pm-forgotten-pr merge dispatch must read the ceiling via active-work-cap.sh --ceiling'
ok "/subagent, /pm, /wave, and /pm-forgotten-pr resolve the ceiling from active-work-cap.sh --ceiling"

# --- no literal ceiling left in slot math -----------------------------------
# The historical literals, in both dash spellings — an alternation, not a
# bracket, so the multi-byte en dash matches under a C locale too. A labelled
# default ("default 4", the shell fallback `CEILING=4` when the script is
# absent) is fine; the band itself, or the slot-math pseudo-code form
# `CEILING    = <n>` (spaces around `=`, which no shell assignment has), is not.
# /pm-forgotten-pr's merge dispatch honours the same ceiling, so it is held to
# the literal checks too.
for FILE in "$SUBAGENT" "$PM" "$WAVE" "$FORGOTTEN"; do
  reject_pattern "$FILE" '3(–|-)4 (concurrent|pipeline|ceiling|active|slots?|parallel|band)' \
    "$FILE still hard-codes the 3–4 band"
  reject_pattern "$FILE" 'CEILING[[:space:]]+=[[:space:]]*[0-9]' \
    "$FILE still assigns a literal CEILING in slot math"
  reject_pattern "$FILE" '1-of-4' "$FILE still hard-codes a 1-of-4 slot example"
done
ok "no consumer hard-codes a numeric ceiling in slot math"

# --- launches fill to LIMIT = min(CEILING, CAP), never the raw ceiling ------
# A consumer that launches up to the bare CEILING outruns ACTIVE_WORK_CAP
# whenever a repo sets the ceiling above the cap (PR #1732 review round 1).
require_text "$FORGOTTEN" 'min(PIPELINE_CEILING, ACTIVE_WORK_CAP)' \
  '/pm-forgotten-pr merge dispatch must launch up to min(PIPELINE_CEILING, ACTIVE_WORK_CAP)'
require_text "$FORGOTTEN" '`--cap`' \
  '/pm-forgotten-pr must read the cap as well as the ceiling'
require_text "$PM" 'up to the **`LIMIT` concurrent-pipeline** limit' \
  '/pm launch guidance must fill up to Step 0 LIMIT'
require_text "$PM" 'below the effective limit (`LIMIT`, Step 0)' \
  '/pm 3.4 refill must trigger below Step 0 LIMIT'
require_text "$PM" '1-of-{LIMIT}' \
  '/pm 3.4 must describe an under-filled board against LIMIT'
reject_pattern "$PM" 'up to the \*\*`CEILING`' \
  '/pm must launch up to Step 0 LIMIT, not the raw CEILING'
reject_pattern "$PM" 'below the ceiling \(`CEILING`|1-of-\{CEILING\}' \
  '/pm 3.4 refill must trigger below Step 0 LIMIT, not the raw CEILING'
ok "/pm and /pm-forgotten-pr launch up to min(CEILING, CAP), not the raw ceiling"

# --- MAX_WAVE may still only lower the ceiling ------------------------------
require_text "$WAVE" 'clamped to [1, CEILING]' \
  '/wave must still clamp MAX_WAVE to [1, CEILING]'
require_text "$WAVE" 'EFFECTIVE  = min(CEILING, CONFIG?)' \
  '/wave must still take min(CEILING, MAX_WAVE)'
ok "/wave's MAX_WAVE still only lowers the resolved ceiling"

echo "OK: pipeline-ceiling consumer checks passed"
