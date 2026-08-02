#!/usr/bin/env bash
# tests/lib/skill-bash.sh — Extract a fenced `bash` block out of a SKILL.md by
# a stable, greppable anchor, so a test can exercise the REAL skill-embedded
# bash instead of a copy that silently drifts.
#
# Source this file (do NOT execute it directly) from a `*.test.sh` suite:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/skill-bash.sh"
#     BLOCK="$(extract_skill_bash "$SKILL_MD" pmm-wake-step-4a-scan)" || exit 1
#
# It lives in `tests/lib/` (not `tests/`) and is deliberately NOT named
# `*.test.sh`, so `.github/scripts/run-hook-tests.sh`'s flat
# `.claude/scripts/tests/*.test.sh` glob never tries to run it as a suite.
#
# WHY THIS EXISTS (issues #871, #887, #888)
#   Skill-embedded bash is production code with no regression coverage. The #871
#   fail-open (`/pmm-wake --auto-check` resuming a paused fleet off a FAILED
#   `gh pr list` scan) lived in a SKILL.md fenced block, survived review, and was
#   only caught later on an unrelated PR. Its fix (PR #887) shipped with no
#   committed test because the verification harness was scratch-only.
#
#   The sibling precedent is `.claude/scripts/tests/pr-state-classify.test.sh`,
#   which `sed`-extracts the real `classify` jq function from `pr-state.sh` so
#   "the two can never drift apart". This library is the same idea for Markdown.
#
# THE ANCHORING RULE (the one design decision this library exists to make)
#   A jq function has a stable named symbol (`def classify:`) to anchor on. A
#   fenced block in Markdown has nothing: heading text ("## Step 4a") and fence
#   ordinal ("the 3rd ```bash block") are both prose-mutable, so anchoring on
#   either turns every editorial reshuffle into a red build — a maintenance tax
#   that gets the test deleted rather than the skill fixed.
#
#   So the anchor is an explicit HTML comment on its own line above the opening
#   fence, reusing the `<!-- key: value -->` idiom already in this repo
#   (`<!-- churn-hotspot: … -->`, `<!-- harness-audit: … -->`):
#
#       <!-- test-anchor: pmm-wake-step-4a-scan -->
#       ```bash
#       …the block a test will run…
#       ```
#
#   It is invisible in rendered prose, survives reordering and rewording, is
#   greppable from the call site, and announces to the next editor that
#   something depends on this block. Blank lines between the anchor and the
#   fence are tolerated; anything else between them is an error, because a
#   drifted anchor must not quietly extract a neighbouring block.
#
# FAIL LOUD, NEVER EMPTY
#   Every failure mode returns non-zero with a message on stderr. A
#   silently-empty extraction is the exact false-clean this must not have: a
#   test that runs zero lines of skill bash passes green forever.
#
# EXIT STATUS of extract_skill_bash
#   0  Block extracted; body written to stdout.
#   2  Usage error (wrong argument count, unreadable Markdown file).
#   3  Anchor not found.
#   4  Anchor is ambiguous (matched more than once in the file).
#   5  First non-blank line after the anchor is not an opening ```bash fence.
#   6  Opening fence is never closed.
#   7  Extracted block body is empty.
#
# Portability: bash 3.2 (macOS system bash) + POSIX awk only. Offline; no jq,
# no git, no network. Mirrors the source-only conventions of
# `.claude/scripts/lib/repo-normalizer.sh`.

# Guard against direct execution — this file defines a function and does nothing
# else, so running it would silently succeed and extract nothing.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  echo "skill-bash.sh: source this file, do not execute it directly" >&2
  exit 2
fi

# extract_skill_bash <markdown-path> <anchor-name>
#   Writes the anchored block body (fence lines excluded) to stdout.
extract_skill_bash() {
  if [ "$#" -ne 2 ]; then
    echo "extract_skill_bash: usage: extract_skill_bash <markdown-path> <anchor-name>" >&2
    return 2
  fi

  # All locals: this file is sourced into a test suite, so leaking these names
  # into the caller could silently clobber one of its variables.
  local md_path anchor_name marker anchor_lines anchor_count anchor_line
  local block_body awk_rc

  md_path="$1"
  anchor_name="$2"

  if [ -z "$anchor_name" ]; then
    echo "extract_skill_bash: anchor name must not be empty" >&2
    return 2
  fi
  if [ ! -r "$md_path" ]; then
    echo "extract_skill_bash: cannot read markdown file: $md_path" >&2
    return 2
  fi

  marker="<!-- test-anchor: ${anchor_name} -->"

  # Pass 1 — locate every line that IS the marker (after trimming surrounding
  # whitespace). Matching the whole trimmed line, not a substring, keeps a
  # longer anchor name from matching a shorter one as a prefix.
  anchor_lines="$(
    awk -v m="$marker" '
      {
        s = $0
        sub(/^[ \t]+/, "", s)
        sub(/[ \t\r]+$/, "", s)
        if (s == m) print NR
      }
    ' "$md_path"
  )"

  anchor_count=0
  if [ -n "$anchor_lines" ]; then
    anchor_count="$(printf '%s\n' "$anchor_lines" | wc -l | tr -d '[:space:]')"
  fi

  if [ "$anchor_count" -eq 0 ]; then
    echo "extract_skill_bash: anchor not found in $md_path: $marker" >&2
    echo "extract_skill_bash: add the anchor on its own line above the target bash fence (blank lines between the two are fine)" >&2
    return 3
  fi
  if [ "$anchor_count" -gt 1 ]; then
    echo "extract_skill_bash: ambiguous anchor in $md_path: $marker matched $anchor_count times (lines: $(printf '%s' "$anchor_lines" | tr '\n' ',' | sed 's/,$//'))" >&2
    echo "extract_skill_bash: anchor names must be unique within a file" >&2
    return 4
  fi

  anchor_line="$anchor_lines"

  # Pass 2 — from the anchor, the next non-blank line must open a bash fence;
  # everything up to the matching closing fence is the block body.
  block_body="$(
    awk -v start="$anchor_line" '
      NR <= start { next }
      state == 0 {
        s = $0
        sub(/^[ \t]+/, "", s)
        sub(/[ \t\r]+$/, "", s)
        if (s == "") next
        if (s == "```bash") { state = 1; next }
        rc = 5
        exit rc
      }
      state == 1 {
        s = $0
        sub(/^[ \t]+/, "", s)
        sub(/[ \t\r]+$/, "", s)
        if (s == "```") { closed = 1; rc = 0; exit rc }
        print
      }
      END {
        if (rc != 0) exit rc
        if (state == 0) exit 5
        if (!closed) exit 6
      }
    ' "$md_path"
  )"
  awk_rc=$?

  if [ "$awk_rc" -eq 5 ]; then
    echo "extract_skill_bash: first non-blank line after the anchor at line $anchor_line of $md_path is not an opening bash fence" >&2
    return 5
  fi
  if [ "$awk_rc" -eq 6 ]; then
    echo "extract_skill_bash: bash fence opened after line $anchor_line of $md_path is never closed" >&2
    return 6
  fi
  if [ "$awk_rc" -ne 0 ]; then
    echo "extract_skill_bash: awk failed with status $awk_rc while extracting $marker from $md_path" >&2
    return "$awk_rc"
  fi

  # A block that extracts to nothing is the false-clean this library exists to
  # prevent — never hand a caller an empty string with a zero return.
  if [ -z "$block_body" ]; then
    echo "extract_skill_bash: extracted block for $marker in $md_path is empty" >&2
    return 7
  fi

  printf '%s\n' "$block_body"
}
