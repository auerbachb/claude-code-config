#!/usr/bin/env bash
# pm-config-get.sh — Extract a named section from .claude/pm-config.md.
#
# PURPOSE
#   Parses the repo-local .claude/pm-config.md using line-anchored level-2
#   headers (`^## ` at column 1) and prints the body of the requested section.
#   Replaces the duplicated awk/sed/prose parsing across 10 PM skills.
#
# USAGE
#   pm-config-get.sh --section <name> [--json] [--file <path>]
#   pm-config-get.sh --list [--json] [--file <path>]
#   pm-config-get.sh --help | -h
#
#   --section <name>  Name of the section to extract (text after `## `, e.g.
#                     "OKRs", "Team"). Required unless --list is passed.
#   --json            Emit structured JSON on stdout instead of raw text.
#                     With --section: {section, content, present}.
#                     With --list:    {sections: [...], file, present}.
#   --list            Print the section names (one per line, or JSON).
#   --file <path>     Override config path. Defaults to .claude/pm-config.md
#                     resolved from the current working directory.
#
# PARSING RULES
#   - Sections are delimited by lines matching `^## ` at column 1. Lines where
#     `##` appears mid-line are not header matches.
#   - Section body = the lines AFTER the header line, UP TO but not including
#     the next `^## ` header line (or EOF).
#   - Extraction is raw and verbatim; no whitespace normalization is applied.
#
# OUTPUT
#   --section raw:  section body on stdout (may be multi-line or empty).
#   --section json: one-line JSON object with .section, .content, .present.
#   --list raw:     one section name per line.
#   --list json:    one-line JSON object with .sections (array), .file, .present.
#
# EXIT STATUS
#   0  Section present (non-empty body).
#   1  Section missing OR present-but-body-empty. With --list, also returned
#      when the file parses successfully but contains zero `^## ` headers.
#   2  Config file missing or unreadable.
#   3  Usage error (unknown flag, missing required arg, conflicting flags).
#
# EXAMPLES
#   pm-config-get.sh --section OKRs
#   pm-config-get.sh --section Team --json | jq -r .content
#   pm-config-get.sh --list
#   pm-config-get.sh --section OKRs --file /path/to/pm-config.md

set -uo pipefail

print_help() {
  sed -n '/^# PURPOSE$/,/^# EXAMPLES$/p' "$0" | sed 's/^# \{0,1\}//'
}

SECTION=""
MODE_LIST=0
EMIT_JSON=0
CONFIG_FILE=""

# Simple loop-based arg parser — matches repo-root.sh / merge-gate.sh style.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --section)
      if [[ $# -lt 2 || -z "${2-}" ]]; then
        echo "pm-config-get.sh: --section requires a value" >&2
        exit 3
      fi
      SECTION="$2"
      shift 2
      ;;
    --section=*)
      SECTION="${1#--section=}"
      if [[ -z "$SECTION" ]]; then
        echo "pm-config-get.sh: --section requires a value" >&2
        exit 3
      fi
      shift
      ;;
    --json)
      EMIT_JSON=1
      shift
      ;;
    --list)
      MODE_LIST=1
      shift
      ;;
    --file)
      if [[ $# -lt 2 || -z "${2-}" ]]; then
        echo "pm-config-get.sh: --file requires a value" >&2
        exit 3
      fi
      CONFIG_FILE="$2"
      shift 2
      ;;
    --file=*)
      CONFIG_FILE="${1#--file=}"
      if [[ -z "$CONFIG_FILE" ]]; then
        echo "pm-config-get.sh: --file requires a value" >&2
        exit 3
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "pm-config-get.sh: unknown flag: $1" >&2
      echo "Run with --help for usage." >&2
      exit 3
      ;;
    *)
      echo "pm-config-get.sh: unexpected positional argument: $1" >&2
      exit 3
      ;;
  esac
done

# Flag validation.
if [[ "$MODE_LIST" -eq 1 && -n "$SECTION" ]]; then
  echo "pm-config-get.sh: --list and --section are mutually exclusive" >&2
  exit 3
fi
if [[ "$MODE_LIST" -eq 0 && -z "$SECTION" ]]; then
  echo "pm-config-get.sh: --section <name> is required (or use --list)" >&2
  exit 3
fi

# Default config path.
if [[ -z "$CONFIG_FILE" ]]; then
  CONFIG_FILE=".claude/pm-config.md"
fi

# --- Missing/unreadable config → exit 2 (contract code). ---
if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
  if [[ "$EMIT_JSON" -eq 1 ]]; then
    if [[ "$MODE_LIST" -eq 1 ]]; then
      jq -cn --arg file "$CONFIG_FILE" '{sections: [], file: $file, present: false}'
    else
      jq -cn --arg section "$SECTION" --arg file "$CONFIG_FILE" \
        '{section: $section, content: "", present: false, file: $file}'
    fi
  fi
  exit 2
fi

# --- --list mode: print section names. ---
if [[ "$MODE_LIST" -eq 1 ]]; then
  # Capture line-anchored `^## <name>` headers; strip the `## ` prefix.
  # Use awk over sed so we reliably get column-1 anchoring.
  SECTIONS_RAW="$(awk '/^## /{sub(/^## /, ""); print}' "$CONFIG_FILE")"
  if [[ "$EMIT_JSON" -eq 1 ]]; then
    if [[ -z "$SECTIONS_RAW" ]]; then
      jq -cn --arg file "$CONFIG_FILE" '{sections: [], file: $file, present: true}'
    else
      printf '%s\n' "$SECTIONS_RAW" | jq -R . | jq -cs \
        --arg file "$CONFIG_FILE" '{sections: ., file: $file, present: true}'
    fi
  else
    if [[ -n "$SECTIONS_RAW" ]]; then
      printf '%s\n' "$SECTIONS_RAW"
    fi
  fi
  if [[ -z "$SECTIONS_RAW" ]]; then
    exit 1
  fi
  exit 0
fi

# --- --section mode: extract body of a named section. ---
# Strategy: walk the file with awk, track whether we're inside the target
# section, emit body lines, and stop at the next `^## ` header. This avoids
# the `sed '1d;$d'` trick that mis-trims when the section is at EOF or when
# the body is only 1 line.
CONTENT="$(
  awk -v target="$SECTION" '
    BEGIN { inside = 0 }
    /^## / {
      # Header line. Check if it matches the target exactly (ignore trailing
      # whitespace). If so, enter the section; if not, leave it.
      header = $0
      sub(/^## /, "", header)
      sub(/[ \t]+$/, "", header)
      if (header == target) {
        inside = 1
        next
      }
      if (inside) { exit }
      next
    }
    inside { print }
  ' "$CONFIG_FILE"
)"

# A section is "present" only if the header was found AND the body is non-empty.
# Use awk again to check header presence independent of body content, because
# an empty-body section (`## Notes\n\n## Next`) should exit 1 per contract
# ("section missing OR present-but-body-empty").
HEADER_FOUND="$(
  awk -v target="$SECTION" '
    /^## / {
      h = $0
      sub(/^## /, "", h)
      sub(/[ \t]+$/, "", h)
      if (h == target) { print "yes"; exit }
    }
  ' "$CONFIG_FILE"
)"

# Trim trailing whitespace (spaces, tabs, newlines) in one pass so
# "## Foo\n\n## Bar" yields empty. Leading whitespace is preserved — callers
# may care about layout. The parameter expansion below computes the longest
# prefix ending in a non-whitespace character, then strips that prefix from
# the end of CONTENT, leaving only the trailing whitespace run to be removed.
CONTENT="${CONTENT%"${CONTENT##*[![:space:]]}"}"

if [[ -z "$CONTENT" ]]; then
  if [[ "$EMIT_JSON" -eq 1 ]]; then
    present_val=false
    [[ "$HEADER_FOUND" == "yes" ]] && present_val=true
    jq -cn --arg section "$SECTION" --arg file "$CONFIG_FILE" \
      --argjson present "$present_val" \
      '{section: $section, content: "", present: $present, file: $file}'
  fi
  exit 1
fi

if [[ "$EMIT_JSON" -eq 1 ]]; then
  jq -cn --arg section "$SECTION" --arg content "$CONTENT" --arg file "$CONFIG_FILE" \
    '{section: $section, content: $content, present: true, file: $file}'
else
  printf '%s\n' "$CONTENT"
fi

exit 0
