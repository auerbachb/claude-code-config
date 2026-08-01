#!/usr/bin/env bash
# portable-handoff-lint.sh — enforce the portability contract of a handoff
# document produced by /pause (issue #901).
#
# PURPOSE
#   The whole value of a portable handoff is that an agent which has never
#   loaded this harness can act on it. That property degrades silently: a
#   document that says "resume at Phase B" or "run .claude/scripts/merge-gate.sh"
#   still *looks* like a handoff, and nothing about writing it fails. The
#   damage only shows up later, in the one session that has no budget left to
#   reconstruct anything.
#
#   So portability is checked here, mechanically, instead of being asserted in
#   prose that a renderer may or may not follow. /pause runs this against the
#   rendered document BEFORE writing or printing it, and a non-zero exit means
#   the document does not ship as-is.
#
# WHAT COUNTS AS UNPORTABLE
#   Five rules, all applied to the whole document (see --list-rules):
#     harness-path           a .claude/ path — this harness's own layout
#     phase-vocabulary       Phase A/B/C, merge_ready, phase-a-fixer, …
#     state-file             session-state / handoff-state / pr-N-handoff
#     skill-invocation       /wrap, /fixpr, … — resolved from the live skill
#                            catalog, not guessed from a regex
#     unrendered-placeholder {LIKE_THIS} — a template that never got filled in
#
#   Plus two structural rules:
#     required-sections      every required heading present AND non-empty
#     working-directory-absolute
#                            the "Working directory:" line exists and names an
#                            absolute path. It is the one address the reader
#                            needs to find uncommitted work, and a relative one
#                            resolves against a checkout they are not in.
#
#   The section list is the contract with the template; keep the two in step.
#     .claude/skills/pause/references/portable-handoff-template.md
#
# THE ONE EXEMPTION
#   An ABSOLUTE path containing `/.claude/worktrees/` is allowed anywhere in the
#   document. That is not a loophole for harness vocabulary — it is the literal
#   filesystem address of the reader's uncommitted work, which happens to sit
#   under a directory this harness named. Withholding it would make the document
#   pass the lint and fail the reader.
#
#   The exemption keys on what the text IS, not on which section it sits in: a
#   leading `/` makes it an address any agent can resolve, while a bare
#   `.claude/worktrees/…` is a this-checkout-only pointer and still fails.
#   `/home/u/repo/.claude/scripts/merge-gate.sh` also still fails — `worktrees`
#   is the only exempt component.
#
#   SPACES: tolerated only in the `Working directory:` field, whose entire value
#   is one path by definition. In free prose a path is a whitespace-delimited
#   token, because "See /tmp/build then repo/.claude/worktrees/x" is genuinely
#   ambiguous — nothing distinguishes a path continuing across a space from
#   separate words, and any space-tolerant rule there lets an unrelated earlier
#   path vouch for a later relative one. A spaced working directory belongs in
#   the field that exists to carry it.
#
# WHY NOT THE LITERAL `/[a-z-]+` FROM THE TICKET
#   That pattern matches /tmp, /usr, /home, and every lowercase leading path
#   segment, so it fails any document that names a real location — which every
#   useful handoff does. Enumerating the actual skill directories detects
#   exactly "a skill name used as a required step" with no false positives, and
#   it keeps working as skills are added or renamed.
#
# USAGE
#   portable-handoff-lint.sh [OPTIONS] <document.md>
#   portable-handoff-lint.sh --list-rules
#
# OPTIONS
#   --repo-root DIR   Repo to resolve the skill catalog from. Defaults to the
#                     git toplevel of the cwd, then to this script's own repo.
#   --list-rules      Print one rule id per line and exit 0.
#   --quiet           Suppress the per-violation report; exit code only.
#   -h, --help        This text.
#
# EXIT STATUS
#   0  clean — the document is portable and structurally complete
#   1  violations found (reported on stdout unless --quiet)
#   2  usage error
#   3  the document could not be read
#
# SAFETY (.claude/rules/safety.md §"Anthropic Quota & Spend Authority")
#   This script reads one Markdown file and the skill directory listing. It
#   computes no token, spend, or quota figure, and gates nothing on one.

set -uo pipefail

RULES="harness-path phase-vocabulary state-file skill-invocation unrendered-placeholder required-sections working-directory-absolute"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'
Usage: portable-handoff-lint.sh [--repo-root DIR] [--quiet] <document.md>
       portable-handoff-lint.sh --list-rules
       portable-handoff-lint.sh --help

Exit: 0 clean | 1 violations | 2 usage error | 3 unreadable document
EOF
}

# Headings the document must carry, each with a non-empty body. Order is not
# enforced — presence and content are. Keep in step with the template.
REQUIRED_SECTIONS=(
  "Start here"
  "What we're working on"
  "Open work"
  "Decisions made this session"
  "Local state on this machine"
)

# The one .claude/ form that is an address rather than a harness pointer. The
# leading slash is load-bearing — see "THE ONE EXEMPTION" above.
WORKTREE_PATH_PREFIX="/.claude/worktrees/"

# The field carrying the reader's working directory, and the section it lives
# in. Both are contracts with the template; a reword there must be mirrored
# here, which is why a MISSING anchor is a violation rather than a silent skip.
WORKDIR_SECTION="Local state on this machine"
WORKDIR_ANCHOR="Working directory:"

DOC=""
REPO_ROOT=""
REPO_ROOT_EXPLICIT=0
QUIET=0

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-rules) printf '%s\n' $RULES; exit 0 ;;
    --quiet) QUIET=1 ;;
    --repo-root)
      [[ $# -ge 2 ]] || { echo "portable-handoff-lint.sh: --repo-root needs a directory" >&2; exit 2; }
      REPO_ROOT="$2"; REPO_ROOT_EXPLICIT=1; shift ;;
    --)
      # Everything after `--` is positional. Falling through to `break` here
      # would drop the document entirely and report "no document given".
      shift
      while (( $# > 0 )); do
        [[ -z "$DOC" ]] || { echo "portable-handoff-lint.sh: only one document may be linted at a time" >&2; exit 2; }
        DOC="$1"; shift
      done
      break ;;
    -*) echo "portable-handoff-lint.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$DOC" ]] || { echo "portable-handoff-lint.sh: only one document may be linted at a time" >&2; exit 2; }
      DOC="$1" ;;
  esac
  shift
done

[[ -n "$DOC" ]] || { echo "portable-handoff-lint.sh: no document given" >&2; usage >&2; exit 2; }
[[ -r "$DOC" ]] || { echo "portable-handoff-lint.sh: cannot read document: $DOC" >&2; exit 3; }

# --- Resolve the skill catalog -------------------------------------------
# A missing catalog must not silently disable the skill-invocation rule: a lint
# that quietly checks four rules instead of five reports a clean document that
# is not clean. Fall back through the candidates, then to a static list.
# An explicit --repo-root is authoritative: if the caller named a root with no
# catalog in it, that is the answer, not an invitation to go find a better one.
# Auto-detection is where the fallback chain belongs.
if (( ! REPO_ROOT_EXPLICIT )); then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.claude/skills" ]]; then
    SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    CANDIDATE=$(cd "$SELF_DIR/../.." 2>/dev/null && pwd)
    [[ -n "$CANDIDATE" && -d "$CANDIDATE/.claude/skills" ]] && REPO_ROOT="$CANDIDATE"
  fi
fi

# Harness commands that are not skill directories in this repo but are just as
# meaningless to an outside agent.
BUILTIN_COMMANDS="loop schedule compact clear config doctor hooks permissions resume agents review init security-review code-review"

# CATALOG_RESOLVED tracks the SKILL directory listing specifically. The builtin
# list above is a supplement, not a catalog — letting it stand in for one would
# leave the rule quietly checking a dozen fixed names while every skill in the
# repo went undetected.
SKILL_NAMES=""
CATALOG_RESOLVED=0
if [[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.claude/skills" ]]; then
  SKILL_NAMES=$(find "$REPO_ROOT/.claude/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
  [[ -n "$SKILL_NAMES" ]] && CATALOG_RESOLVED=1
fi

# Longest-first so `/pm-handoff` is preferred over `/pm` when both could match,
# which keeps the reported violation text honest.
COMMAND_ALTERNATION=$(
  printf '%s\n' $SKILL_NAMES $BUILTIN_COMMANDS \
    | grep -E '^[a-z][a-z0-9-]*$' \
    | sort -u \
    | awk '{ print length, $0 }' | sort -rn -k1,1 | cut -d' ' -f2- \
    | paste -sd'|' -
)

# --- Rule patterns --------------------------------------------------------
# Bash ERE. Each is checked per line, against a copy of the line with any
# permitted text already masked out.
RE_HARNESS_PATH='\.claude/'
RE_PHASE_VOCAB='(^|[^[:alnum:]_-])(Phase[[:space:]]+[ABC]|merge_ready|phase-[abc]-[a-z]+)([^[:alnum:]_-]|$)'
RE_STATE_FILE='(session-state|session_state|handoff-state|handoff_state|pr-[0-9]+-handoff)'
RE_PLACEHOLDER='\{[A-Z][A-Z0-9_]*\}'
if (( CATALOG_RESOLVED )) && [[ -n "$COMMAND_ALTERNATION" ]]; then
  RE_SKILL_INVOCATION="(^|[^[:alnum:]_/-])/(${COMMAND_ALTERNATION})([^[:alnum:]_-]|\$)"
else
  # No catalog. Fail closed on the SHAPE rather than checking one rule fewer and
  # calling the result clean — a lint that silently narrows is worse than one
  # that is occasionally noisy, because only the narrowing is invisible.
  #
  # `{1,}` (2+ chars total), not `{2,}`: the shortest skill names are the most
  # common ones (/pm, /go), so a 3-char floor would let precisely those through
  # the branch whose whole job is to be over-broad. Some extra noise here is the
  # intended trade — this path only runs when the catalog is unreachable.
  RE_SKILL_INVOCATION='(^|[^[:alnum:]_/-])/[a-z][a-z0-9-]{1,}([^[:alnum:]_/.-]|$)'
fi

# Mask the permitted worktree form, and ONLY where it is part of a genuine
# ABSOLUTE path. A blanket substring swap would also hide
# `repo/.claude/worktrees/x` and `./.claude/worktrees/x`, which are
# this-checkout-only pointers the reader cannot resolve.
#
# Splitting on whitespace was the obvious way to test "is this token
# absolute?", and it was wrong: directory names contain spaces, so
# `/Users/n/My Work/.claude/worktrees/b` split into pieces, the piece holding
# `.claude/` did not start with `/`, and a perfectly valid working directory
# got reported as a harness path.
#
# Instead: for each occurrence, ask whether the text BEFORE it contains an
# absolute-path start — a `/` at line start or after whitespace (allowing an
# opening bracket or quote in between). Spaces inside the path are then
# irrelevant, while `repo/…` and `./…` still have no such start and stay
# visible to harness-path.
# Two different jobs, so two different rules — because "is this an absolute
# path?" is only answerable where the grammar says the text IS a path.
#
# In free prose a path is a whitespace-delimited token, full stop. Trying to
# tolerate spaces there is unresolvable: in
#   "See /tmp/build then repo/.claude/worktrees/x"
# nothing distinguishes "then repo/..." continuing the /tmp path from it being
# separate words, so any space-tolerant rule lets the unrelated /tmp vouch for
# the relative harness path that follows.
#
# The `Working directory:` line is different: its entire value is one path by
# definition, so a space in it is unambiguous and must be honoured — that is the
# real case (`/Users/n/My Work/repo/...`) this exemption exists for.
# A URL is an address any reader can open, so a repository link that happens to
# point at a harness file is a portable reference — unlike a local path, which
# only resolves inside this checkout. Whitespace tokenizing IS sound here
# specifically because URLs cannot contain unescaped spaces.
mask_urls() {
  local in="$1" out="" tok bare
  local -a parts
  read -ra parts <<<"$in"
  for tok in ${parts+"${parts[@]}"}; do
    bare="${tok#[\`\(\[\<\"\']}"
    if [[ "$bare" == http://* || "$bare" == https://* ]]; then
      tok="${tok//.claude\//<url>/}"
    fi
    out+="$tok "
  done
  printf '%s' "$out"
}

mask_worktree_paths() { # $1 = line, $2 = 1 when this is the Working directory line
  local in="$1" is_field="${2:-0}" out="" tok bare value
  local -a parts

  if (( is_field )); then
    value="${in#*"$WORKDIR_ANCHOR"}"
    value="${value#"${value%%[![:space:]]*}"}"
    # The whole value is the path, spaces included — exempt only if it is absolute.
    if [[ "$value" == /* ]]; then
      printf '%s' "${in//"$WORKTREE_PATH_PREFIX"//<worktree>/}"
      return
    fi
    printf '%s' "$in"
    return
  fi

  read -ra parts <<<"$in"
  for tok in ${parts+"${parts[@]}"}; do
    bare="${tok#[\`\(\[\<\"\']}"
    if [[ "$bare" == /*"$WORKTREE_PATH_PREFIX"* ]]; then
      tok="${tok//"$WORKTREE_PATH_PREFIX"//<worktree>/}"
    fi
    out+="$tok "
  done
  printf '%s' "$out"
}

VIOLATIONS=0
REPORT=""

# The document quotes issue titles, review comments, and branch names — text
# other people and bots wrote. Escape sequences in that text cause two distinct
# problems, so this runs BEFORE matching, not just before display:
#
#   1. Display — a raw ANSI escape echoed to a terminal can repaint or hide the
#      very diagnostic that is reporting on it.
#   2. Detection — most of a CSI sequence is ordinary printable text, so
#      `\033[31m/wrap` puts an `m` immediately before `/wrap`, and every rule
#      here treats a preceding alphanumeric as "not a command". Colouring a
#      line would hide the violation in it.
#
# So: strip whole CSI sequences, then turn any remaining C0 control into a
# space (a separator, not a deletion — deleting would glue tokens together).
# Tab and newline are already handled by the reader.
sanitize_line() {
  printf '%s' "$1" \
    | LC_ALL=C sed $'s/\033\\[[0-9;?]*[ -\/]*[@-~]//g; s/\033[@-_]//g' \
    | LC_ALL=C tr '\000-\010\013\014\016-\037\177' '     '
}

report() { # rule, lineno, section, line
  VIOLATIONS=$((VIOLATIONS + 1))
  local section="${3:-<no section>}"
  REPORT+=$(printf '%s:%s: [%s] in "%s": %s\n' "$DOC" "$2" "$1" "$section" "$4")
  REPORT+=$'\n'
}

# --- Scan -----------------------------------------------------------------
declare -a SEEN_SECTIONS=()
declare -a NONEMPTY_SECTIONS=()
section=""
lineno=0
WORKDIR_SEEN=0

while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  # Sanitize once, here — every rule, the section parser, and the report all
  # operate on the cleaned line, so an escape can neither hide a violation nor
  # corrupt the diagnostic.
  line=$(sanitize_line "$line")

  # "Structure, not body content" and "not checked" are DIFFERENT exemptions,
  # and conflating them was a hole: skipping every line starting with `#` meant
  # a shell-comment line inside a fence — `# .claude/scripts/merge-gate.sh` —
  # was neither counted as content nor scanned for violations. Headings are
  # text the reader sees, so every rule below runs on every line; only the
  # non-empty-content tally excludes headings.
  IS_HEADING=0
  if [[ "$line" == '## '* ]]; then
    section="${line#'## '}"
    # Trim trailing whitespace so " Open work " matches "Open work".
    section="${section%"${section##*[![:space:]]}"}"
    SEEN_SECTIONS+=("$section")
    IS_HEADING=1
  elif [[ "$line" =~ ^#{1,6}([[:space:]]|$) ]]; then
    IS_HEADING=1
  fi

  if (( ! IS_HEADING )) && [[ -n "${line//[[:space:]]/}" && -n "$section" ]]; then
    NONEMPTY_SECTIONS+=("$section")
  fi

  # The working-directory field: present, and an absolute path.
  IS_WORKDIR_LINE=0
  if (( ! IS_HEADING )) && [[ "$section" == "$WORKDIR_SECTION" && "$line" == "$WORKDIR_ANCHOR"* ]]; then
    IS_WORKDIR_LINE=1
  fi
  if (( IS_WORKDIR_LINE )); then
    WORKDIR_SEEN=1
    workdir="${line#"$WORKDIR_ANCHOR"}"
    workdir="${workdir#"${workdir%%[![:space:]]*}"}"   # strip leading blanks
    if [[ "$workdir" != /* ]]; then
      report "working-directory-absolute" "$lineno" "$section" \
        "working directory must be an absolute path, got: ${workdir:-<empty>}"
    fi
  fi

  # Mask the one permitted .claude/ form before any rule sees the line.
  scan=$(mask_worktree_paths "$(mask_urls "$line")" "$IS_WORKDIR_LINE")
  # Fail CLOSED on an internal fault. If masking ever breaks, `scan` goes empty
  # and every rule below silently matches nothing — the lint would report a
  # clean document while checking none of it. Refuse instead.
  if [[ -n "${line//[[:space:]]/}" && -z "${scan//[[:space:]]/}" ]]; then
    echo "portable-handoff-lint.sh: internal error — line $lineno produced an empty scan buffer; refusing to report a result" >&2
    exit 4
  fi

  [[ "$scan" =~ $RE_HARNESS_PATH ]] && report "harness-path" "$lineno" "$section" "$line"
  [[ "$scan" =~ $RE_PHASE_VOCAB ]] && report "phase-vocabulary" "$lineno" "$section" "$line"
  [[ "$scan" =~ $RE_STATE_FILE ]] && report "state-file" "$lineno" "$section" "$line"
  [[ "$scan" =~ $RE_SKILL_INVOCATION ]] && report "skill-invocation" "$lineno" "$section" "$line"
  [[ "$scan" =~ $RE_PLACEHOLDER ]] && report "unrendered-placeholder" "$lineno" "$section" "$line"
done < "$DOC"

# --- Structural rule ------------------------------------------------------
# An "empty shell" — correct headings, nothing under them — is the failure mode
# graceful degradation is most likely to produce, so absence and emptiness are
# both violations, reported distinctly.
contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

for want in "${REQUIRED_SECTIONS[@]}"; do
  if ! contains "$want" ${SEEN_SECTIONS+"${SEEN_SECTIONS[@]}"}; then
    report "required-sections" "0" "$want" "required section is missing"
  elif ! contains "$want" ${NONEMPTY_SECTIONS+"${NONEMPTY_SECTIONS[@]}"}; then
    report "required-sections" "0" "$want" "required section is present but empty"
  fi
done

# A missing anchor is a violation, not a pass. Were it a silent skip, rewording
# the template would disable this rule instead of failing loudly — the exact
# way a check stops checking without anyone noticing.
if contains "$WORKDIR_SECTION" ${SEEN_SECTIONS+"${SEEN_SECTIONS[@]}"} && (( ! WORKDIR_SEEN )); then
  report "working-directory-absolute" "0" "$WORKDIR_SECTION" \
    "no \"$WORKDIR_ANCHOR\" line — the reader has no way to locate the work"
fi

if (( VIOLATIONS > 0 )); then
  if (( ! QUIET )); then
    printf '%s' "$REPORT"
    printf 'portable-handoff-lint: %d violation(s) in %s\n' "$VIOLATIONS" "$DOC"
    printf 'The document is not portable as written. Rewrite each line above in plain English — say what to do and where, not which part of this harness does it.\n'
  fi
  exit 1
fi

(( QUIET )) || printf 'portable-handoff-lint: OK (%s)\n' "$DOC"
exit 0
