# shellcheck shell=bash
# desk/tests/lib/skill-block.sh — extracts a fenced bash block from a desk
# skill file by its `<!-- test-anchor: NAME -->` comment, so a test runs the
# skill's own bash rather than a copy that drifts (issue #1780). Sourced,
# never executed. The anchor sits on its own line above the ```bash fence;
# blank lines may separate them, nothing else may.
#
# hq_t_skill_block FILE NAME
#   Prints the block's body with the fence's indentation removed (blocks
#   inside list items are indented). Returns non-zero with one line on
#   stderr when the anchor is missing (3) or repeated (4), when something
#   other than a ```bash fence follows it (5), when the fence never closes
#   (6), or when the body is empty (7): a test must never run an empty block
#   and pass.
hq_t_skill_block() {
  local file="$1" name="$2" out rc=0
  out=$(awk -v anchor="<!-- test-anchor: $name -->" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    trim($0) == anchor { hits++; if (hits == 1) state = 1; next }
    state == 1 {
      if (trim($0) == "") next
      if ($0 ~ /^ *```bash[ \t]*$/) { indent = index($0, "`") - 1; state = 2; next }
      bad = 1; state = 9; next
    }
    state == 2 {
      line = $0
      if (line ~ /^ *```[ \t]*$/) { state = 3; next }
      if (substr(line, 1, indent) ~ /^ *$/) line = substr(line, indent + 1)
      body = body line "\n"; n++
      next
    }
    END {
      if (hits == 0) { print "skill-block: anchor " anchor " not found" > "/dev/stderr"; exit 3 }
      if (hits > 1) { print "skill-block: anchor " anchor " appears more than once" > "/dev/stderr"; exit 4 }
      if (bad) { print "skill-block: anchor " anchor " is not followed by a ```bash fence" > "/dev/stderr"; exit 5 }
      if (state != 3) { print "skill-block: the block after " anchor " is never closed" > "/dev/stderr"; exit 6 }
      if (n == 0) { print "skill-block: the block after " anchor " is empty" > "/dev/stderr"; exit 7 }
      printf "%s", body
    }' "$file") || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  printf '%s\n' "$out"
}
