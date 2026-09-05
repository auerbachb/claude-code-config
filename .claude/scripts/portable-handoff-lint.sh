#!/usr/bin/env bash
# portable-handoff-lint.sh — enforce the portability contract of a handoff
# catalog: utilities — Enforce portable handoff structure, working-copy identity, cross-agent resume guidance, and freedom from harness-only references
# document produced by /end (issue #901).
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
#   prose that a renderer may or may not follow. /end runs this against the
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
#   Plus seven structural rules:
#     required-sections      every required heading present AND non-empty
#     working-directory-absolute
#                            the "Working directory:" line exists and names an
#                            absolute path. It is the one address the reader
#                            needs to find uncommitted work, and a relative one
#                            resolves against a checkout they are not in.
#     open-work-ownership    every entry under "Open work" says who owns it
#     pull-request-review-state
#                            every pull-request entry says what it is waiting on
#                            AND whether it is approved
#     verification-command   at least one "Verify with:" command, whenever there
#                            is any in-flight work to verify
#     working-copy-fields    repository/worktree/Git identity fields all exist
#                            with explicit values
#     resume-guidance        the dedicated resume section names `/end-resume`
#                            and states how duplicate relaunches are avoided
#
#   The section list is the contract with the template; keep the two in step.
#     .claude/skills/end/references/portable-handoff-template.md
#
# WHAT THE LAST THREE RULES CAN AND CANNOT PROVE (issue #912)
#   They came out of a cold read: a document that passed every rule above was
#   handed to an agent holding the repository and nothing else. It answered what
#   to do first, which pull requests were open, and what each was waiting on —
#   and could not say who owned the half-finished work, whether anything was
#   approved, or how to check that a change worked.
#
#   So these three check that the field is PRESENT and has a value. They cannot
#   check that the value is any good: "Owner: yes" passes. That limit is the
#   point of the exercise rather than a shortcoming of it — no grep decides
#   whether a document says enough, which is why the cold read was a manual test
#   and why the template carries judgement rules these rules do not mirror.
#
#   Entries are recognized by the template's own shape: a top-level list item
#   (`- `, `* `, `+ ` at column zero) inside "Open work". An indented sub-bullet
#   continues the entry it sits under rather than starting a new one, so an
#   entry may be as long as it needs to be. A renderer that abandons the bullet
#   form altogether is off-template in a way this rule cannot see; the template
#   is the contract, and these rules enforce it, not replace it.
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
#   4  internal fault — either a line produced an empty scan buffer, or the
#      scan stopped before the end of the document, so the rules did not run
#      against everything. Reported rather than passed: a checker that can say
#      "clean" while checking nothing is the failure this script prevents.
#
# SAFETY (.claude/rules/safety.md §"Anthropic Quota & Spend Authority")
#   This script reads one Markdown file and the skill directory listing. It
#   computes no token, spend, or quota figure, and gates nothing on one.

set -uo pipefail

RULES="harness-path phase-vocabulary state-file skill-invocation unrendered-placeholder required-sections working-directory-absolute open-work-ownership pull-request-review-state verification-command working-copy-fields resume-guidance"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'
Usage: portable-handoff-lint.sh [--repo-root DIR] [--quiet] <document.md>
       portable-handoff-lint.sh --list-rules
       portable-handoff-lint.sh --help

Exit: 0 clean | 1 violations | 2 usage error | 3 unreadable document | 4 internal fault
EOF
}

# Headings the document must carry, each with a non-empty body. Order is not
# enforced — presence and content are. Keep in step with the template.
REQUIRED_SECTIONS=(
  "Start here"
  "What we're working on"
  "Open work"
  "Progress and verification"
  "Decisions made this session"
  "Local state on this machine"
  "Resume safely"
)

# The one .claude/ form that is an address rather than a harness pointer. The
# leading slash is load-bearing — see "THE ONE EXEMPTION" above.
WORKTREE_PATH_PREFIX="/.claude/worktrees/"

# The field carrying the reader's working directory, and the section it lives
# in. Both are contracts with the template; a reword there must be mirrored
# here, which is why a MISSING anchor is a violation rather than a silent skip.
WORKDIR_SECTION="Local state on this machine"
WORKDIR_ANCHOR="Working directory:"
WORKING_COPY_ANCHORS=(
  "Repository identity:"
  "Repository root:"
  "Working directory:"
  "Worktree condition:"
  "Branch:"
  "Base branch:"
  "HEAD commit:"
  "Tracked changes:"
  "Untracked changes:"
  "Unpushed commits:"
)
RESUME_SECTION="Resume safely"
RESUME_ANCHOR="Resume command:"
AGENT_ANCHOR="For another agent:"
RELAUNCH_ANCHOR="Relaunch rule:"

# Per-entry field anchors, same contract: reword one in the template and the
# matching rule must be reworded here, or it stops firing without saying so.
OPEN_WORK_SECTION="Open work"
OWNER_ANCHOR="Owner:"
WAITING_ANCHOR="Waiting on:"
APPROVAL_ANCHOR="Approval:"
VERIFY_ANCHOR="Verify with:"

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
BUILTIN_COMMANDS="loop schedule compact clear config doctor hooks permissions resume agents review init security-review code-review stop"

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
# Case-insensitive on purpose. "phase b" carries exactly the same internal
# meaning as "Phase B", so a capital letter cannot be what decides whether the
# jargon ships. The cost is a possible false positive on prose like "in a later
# phase a decision was made" — worth paying, because a false positive is a
# reword and a false negative is a reader who cannot act on the document.
RE_PHASE_VOCAB='(^|[^[:alnum:]_-])([Pp]hase[[:space:]]+[ABCabc]|[Mm]erge_[Rr]eady|[Pp]hase-[abcABC]-[a-zA-Z]+)([^[:alnum:]_-]|$)'
RE_STATE_FILE='(session-state|session_state|handoff-state|handoff_state|pr-[0-9]+-handoff)'
RE_PLACEHOLDER='\{[A-Z][A-Z0-9_]*\}'
# A top-level list item at column zero starts an entry; an indented one
# continues the entry above it, so an entry can carry sub-bullets.
RE_ENTRY_BULLET='^[-*+][[:space:]]+[^[:space:]]'
# Leading non-alphanumerics are skipped so `**Pull request 903 — …**` is
# recognized without depending on how the title was emphasized.
RE_PR_ENTRY='^[^[:alnum:]]*([Pp]ull[[:space:]]+[Rr]equest|[Pp][Rr])[[:space:]]+#?[0-9]+'
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
# Strip every leading Markdown/quoting delimiter, not just one character. A
# path is routinely written as `**/Users/u/repo/...**` or `"/Users/..."`, and a
# single-character strip leaves the second asterisk in front of the slash — so a
# perfectly valid absolute path reads as relative and gets rejected.
strip_open_delims() {
  local v="$1"
  # A Markdown link puts the destination after "](", so the leading run is link
  # TEXT, not delimiters — stripping characters one at a time never reaches the
  # path. Jump to the destination first.
  case "$v" in *']('*) v="${v##*](}" ;; esac
  while [[ -n "$v" && "$v" == [\`\(\[\<\"\'*_~]* ]]; do v="${v:1}"; done
  printf '%s' "$v"
}

# Leading emphasis (and a blockquote marker) at the START OF A LINE. Not
# strip_open_delims: that one jumps past a Markdown link destination, which is
# right for a single token and wrong for a whole line — a field line reading
# `Owner: mine, see [the note](https://x)` would lose its own label and the
# field would read as absent.
strip_leading_emphasis() {
  local v="$1"
  while :; do
    case "$v" in
      [\`*_~\>]*)   v="${v:1}" ;;
      [[:space:]]*) v="${v#"${v%%[![:space:]]*}"}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$v"
}

# A field whose value is only markup is the empty-shell failure at field scale:
# `Owner:` with nothing after it, or `Owner: **`, answers the reader's question
# with the shape of an answer. The test is what the reader SEES, so every
# construct that renders to nothing has to come out before the emptiness check
# — `Owner: **mine**` is a perfectly good answer and must survive it.
#
# Deleting characters one class at a time is not enough on its own: an HTML
# comment and an empty Markdown link both leave non-whitespace behind while
# rendering to nothing at all, so `Owner: <!-- -->` and `Owner: [](/note)` would
# each answer the question with a blank. Two constructs are therefore REDUCED
# rather than deleted, because one of them can carry visible text: a comment
# renders nothing and comes out whole, a link renders as its TEXT, so
# `Owner: [mine](url)` keeps "mine" and `Owner: [](/note)` keeps nothing.
field_value_nonempty() {
  local v="$1" backtick head rest text after

  # `<!-- ... -->`: cut from the FIRST opener to the first closer AFTER it.
  # Taking the first closer in the whole string can land left of the opener and
  # reassemble into something longer, which would never terminate. Each pass
  # here removes at least the seven delimiter characters and adds none.
  while [[ "$v" == *'<!--'*'-->'* ]]; do
    head="${v%%'<!--'*}"
    rest="${v#*'<!--'}"
    [[ "$rest" == *'-->'* ]] || break
    v="$head${rest#*'-->'}"
  done

  # `[text](dest)` -> `text`. The destination is an address, not something that
  # appears on the page; the text is the part the reader can actually read.
  while [[ "$v" == *'['*']('*')'* ]]; do
    head="${v%%'['*}"
    rest="${v#*'['}"
    [[ "$rest" == *']('* ]] || break
    text="${rest%%']('*}"
    after="${rest#*']('}"
    [[ "$after" == *')'* ]] || break
    v="$head$text${after#*')'}"
  done

  # Via a variable, NOT inline: `${v//$'\x60'/}` expands the escape first and
  # leaves a bare backtick inside the braces, which reads as an unterminated
  # command substitution and aborts the caller mid-loop. Quoting the expansion
  # of a variable keeps the character as data.
  backtick=$'\140'
  v="${v//[[:space:]]/}"
  v="${v//\*/}"
  v="${v//_/}"
  v="${v//\~/}"
  v="${v//"$backtick"/}"
  [[ -n "$v" ]]
}

# A URL is an address any reader can open, so a repository link that happens to
# point at a harness file is a portable reference — unlike a local path, which
# only resolves inside this checkout. Whitespace tokenizing IS sound here
# specifically because URLs cannot contain unescaped spaces.
mask_urls() {
  local in="$1" out="" tok bare
  local -a parts
  read -ra parts <<<"$in"
  for tok in ${parts+"${parts[@]}"}; do
    bare=$(strip_open_delims "$tok")
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
    bare=$(strip_open_delims "$tok")
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

# --- Open-work entry state ------------------------------------------------
# An entry runs from its top-level bullet to the next one, or to the next
# heading, or to end of file. Judged at that boundary rather than inline,
# because "the field is missing" is only knowable once the entry is over.
ENTRY_ACTIVE=0
ENTRY_LINENO=0
ENTRY_LABEL=""
ENTRY_IS_PR=0
ENTRY_HAS_OWNER=0
ENTRY_HAS_WAITING=0
ENTRY_HAS_APPROVAL=0
OPEN_WORK_ENTRIES=0
VERIFY_SEEN=0

flush_entry() {
  (( ENTRY_ACTIVE )) || return 0
  ENTRY_ACTIVE=0
  if (( ! ENTRY_HAS_OWNER )); then
    report "open-work-ownership" "$ENTRY_LINENO" "$OPEN_WORK_SECTION" \
      "no \"$OWNER_ANCHOR\" line on \"$ENTRY_LABEL\" — an unmarked item reads as free to take"
  fi
  (( ENTRY_IS_PR )) || return 0
  if (( ! ENTRY_HAS_WAITING )); then
    report "pull-request-review-state" "$ENTRY_LINENO" "$OPEN_WORK_SECTION" \
      "no \"$WAITING_ANCHOR\" line on \"$ENTRY_LABEL\" — the reader cannot tell what is blocking it"
  fi
  if (( ! ENTRY_HAS_APPROVAL )); then
    report "pull-request-review-state" "$ENTRY_LINENO" "$OPEN_WORK_SECTION" \
      "no \"$APPROVAL_ANCHOR\" line on \"$ENTRY_LABEL\" — unblocked is not the same as allowed to merge"
  fi
}

# --- Scan -----------------------------------------------------------------
declare -a SEEN_SECTIONS=()
declare -a NONEMPTY_SECTIONS=()
section=""
lineno=0
WORKDIR_SEEN=0
declare -a WORKING_COPY_FIELDS_SEEN=()
RESUME_SEEN=0
RESUME_FIELDS=0
AGENT_SEEN=0
AGENT_FIELDS=0
RELAUNCH_SEEN=0
IN_FENCE=0

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
  # Track fenced-code state. A `## ...` inside a code block is sample text, not
  # a section — and Step 6 prints the finished document inside a fence, so a
  # render that accidentally captured its own fence would otherwise satisfy
  # every structural rule while the reader sees one undifferentiated code block.
  case "${line//[[:space:]]/}" in
    '```'*|'~~~'*) IN_FENCE=$(( IN_FENCE ? 0 : 1 )) ;;
  esac

  # A heading closes any open entry — before `section` changes under it, or the
  # entry would be judged against the section it does not belong to.
  if (( ! IN_FENCE )) && [[ "$line" =~ ^#{1,6}([[:space:]]|$) ]]; then
    flush_entry
  fi

  IS_HEADING=0
  if (( ! IN_FENCE )) && [[ "$line" == '## '* ]]; then
    section="${line#'## '}"
    # Trim trailing whitespace so " Open work " matches "Open work".
    section="${section%"${section##*[![:space:]]}"}"
    SEEN_SECTIONS+=("$section")
    IS_HEADING=1
  elif (( ! IN_FENCE )) && [[ "$line" =~ ^#{1,6}([[:space:]]|$) ]]; then
    IS_HEADING=1
  fi

  # Structural-only markup is not an answer to the reader. A section holding
  # just a fence pair or an HTML comment would otherwise satisfy the
  # non-empty check while telling them nothing, which is the empty-shell
  # failure wearing a disguise.
  IS_STRUCTURAL_ONLY=0
  case "${line//[[:space:]]/}" in
    '```'*|'~~~'*|'<!--'*'-->'|'') IS_STRUCTURAL_ONLY=1 ;;
  esac
  if (( ! IS_HEADING )) && (( ! IS_STRUCTURAL_ONLY )) && [[ -n "$section" ]]; then
    NONEMPTY_SECTIONS+=("$section")
  fi

  # --- Open-work entries ---------------------------------------------------
  # Ownership, review state, and a way to verify. Tracked here, judged at the
  # entry boundary in flush_entry.
  trimmed="${line#"${line%%[![:space:]]*}"}"
  field=$(strip_leading_emphasis "$trimmed")

  # The content test excludes a thematic break written as `* * *`, which is a
  # horizontal rule the reader sees as a divider, not an item to own.
  if (( ! IN_FENCE )) && [[ "$section" == "$OPEN_WORK_SECTION" ]] \
     && [[ "$line" =~ $RE_ENTRY_BULLET ]] \
     && [[ -n "${line//[-*+_[:space:]]/}" ]]; then
    flush_entry
    ENTRY_ACTIVE=1
    ENTRY_LINENO=$lineno
    ENTRY_HAS_OWNER=0
    ENTRY_HAS_WAITING=0
    ENTRY_HAS_APPROVAL=0
    OPEN_WORK_ENTRIES=$((OPEN_WORK_ENTRIES + 1))
    ENTRY_LABEL="${line#[-*+]}"
    ENTRY_LABEL="${ENTRY_LABEL#"${ENTRY_LABEL%%[![:space:]]*}"}"
    ENTRY_LABEL="${ENTRY_LABEL//\*/}"
    ENTRY_LABEL="${ENTRY_LABEL:0:60}"
    ENTRY_IS_PR=0
    [[ "$ENTRY_LABEL" =~ $RE_PR_ENTRY ]] && ENTRY_IS_PR=1
  fi

  # Fenced text is a sample, not an answer — the entry bullet, the headings and
  # the working-directory field all already refuse to read it, and a field that
  # still did would let an example vouch for the entry containing it. The
  # sharpest case is the one the fence tracking exists for: Step 6 prints the
  # finished document inside a fence, so a render that captured its own fence
  # would supply every field from its own sample copy.
  if (( ENTRY_ACTIVE )) && (( ! IN_FENCE )); then
    case "$field" in
      "$OWNER_ANCHOR"*)
        field_value_nonempty "${field#"$OWNER_ANCHOR"}" && ENTRY_HAS_OWNER=1 ;;
      "$WAITING_ANCHOR"*)
        field_value_nonempty "${field#"$WAITING_ANCHOR"}" && ENTRY_HAS_WAITING=1 ;;
      "$APPROVAL_ANCHOR"*)
        field_value_nonempty "${field#"$APPROVAL_ANCHOR"}" && ENTRY_HAS_APPROVAL=1 ;;
    esac
  fi

  # Document-scoped: one runnable check somewhere is the bar, not one per entry.
  # A queued issue nobody has started has nothing to verify, and demanding a
  # command there would buy filler instead of an answer. Document-scoped makes
  # the fence gate matter MORE, not less: one fenced sample anywhere would
  # otherwise answer for the whole document.
  if (( ! IN_FENCE )); then
    case "$field" in
      "$VERIFY_ANCHOR"*)
        field_value_nonempty "${field#"$VERIFY_ANCHOR"}" && VERIFY_SEEN=$((VERIFY_SEEN + 1)) ;;
    esac
  fi

  # The working-directory field: present, and an absolute path.
  IS_WORKDIR_LINE=0
  if (( ! IS_HEADING )) && (( ! IN_FENCE )) && [[ "$section" == "$WORKDIR_SECTION" && "$line" == "$WORKDIR_ANCHOR"* ]]; then
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

  # Required takeover fields. Each anchor must occur once with a visible value;
  # explicit "unknown" / "not applicable" values are honest answers and pass.
  if (( ! IS_HEADING )) && (( ! IN_FENCE )) && [[ "$section" == "$WORKDIR_SECTION" ]]; then
    for anchor in "${WORKING_COPY_ANCHORS[@]}"; do
      if [[ "$line" == "$anchor"* ]]; then
        WORKING_COPY_FIELDS_SEEN+=("$anchor")
        if ! field_value_nonempty "${line#"$anchor"}"; then
          report "working-copy-fields" "$lineno" "$WORKDIR_SECTION" \
            "empty \"$anchor\" field — record the value or an explicit unknown/not-applicable marker"
        fi
      fi
    done
  fi

  resume_value=""
  if (( ! IS_HEADING )) && (( ! IN_FENCE )) && [[ "$section" == "$RESUME_SECTION" ]]; then
    if [[ "$line" == "$RESUME_ANCHOR"* ]]; then
      RESUME_FIELDS=$((RESUME_FIELDS + 1))
      resume_value="${line#"$RESUME_ANCHOR"}"
      resume_value="${resume_value#"${resume_value%%[![:space:]]*}"}"
      if field_value_nonempty "$resume_value"; then
        case "$resume_value" in
          /end-resume|/end-resume\ *) RESUME_SEEN=$((RESUME_SEEN + 1)) ;;
          "not applicable"|"not applicable "*) RESUME_SEEN=$((RESUME_SEEN + 1)) ;;
        esac
      fi
    fi
    if [[ "$line" == "$AGENT_ANCHOR"* ]]; then
      AGENT_FIELDS=$((AGENT_FIELDS + 1))
      if field_value_nonempty "${line#"$AGENT_ANCHOR"}"; then
        AGENT_SEEN=$((AGENT_SEEN + 1))
      fi
    fi
    if [[ "$line" == "$RELAUNCH_ANCHOR"* ]] && field_value_nonempty "${line#"$RELAUNCH_ANCHOR"}"; then
      RELAUNCH_SEEN=1
    fi
  fi

  # Mask the one permitted .claude/ form before any rule sees the line.
  scan=$(mask_worktree_paths "$(mask_urls "$line")" "$IS_WORKDIR_LINE")
  # `/end-resume` is meaningful handoff metadata only in its dedicated field;
  # mask that exact occurrence while every other harness command still fails.
  if [[ "$section" == "$RESUME_SECTION" && "$line" == "$RESUME_ANCHOR"* ]]; then
    case "$resume_value" in
      /end-resume|/end-resume\ *) scan="${scan/\/end-resume/<resume-entrypoint>}" ;;
    esac
  fi
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

# Did the scan actually reach the end? A fatal expansion inside the loop body
# terminates the loop where it stands, and everything after that line goes
# unchecked while the script carries on to print a verdict. That was not
# hypothetical: an inline `$'\x60'` in a substitution pattern did exactly this
# during development, and the run still ended in a confident report. Counting
# what was read against what exists turns silent truncation into exit 4.
# `awk END{NR}` matches the loop's semantics, final unterminated line included.
DOC_LINES=$(LC_ALL=C awk 'END { print NR }' "$DOC" 2>/dev/null)
if [[ ! "$DOC_LINES" =~ ^[0-9]+$ ]] || (( lineno != DOC_LINES )); then
  echo "portable-handoff-lint.sh: internal error — scanned ${lineno} of ${DOC_LINES:-?} lines of $DOC; refusing to report a result" >&2
  exit 4
fi

# The last entry ends at end of file, not at a boundary the loop can see.
flush_entry

# In-flight work the reader cannot check is work they cannot finish. Scoped to
# documents that HAVE in-flight work: "Nothing is in flight." is a complete
# answer, and a command demanded there would be invented to satisfy the rule.
if (( OPEN_WORK_ENTRIES > 0 && VERIFY_SEEN == 0 )); then
  report "verification-command" "0" "$OPEN_WORK_SECTION" \
    "no \"$VERIFY_ANCHOR\" line anywhere — $OPEN_WORK_ENTRIES item(s) in flight and no way given to check any of them"
fi

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

count_of() {
  local needle="$1"; shift
  local item n=0
  for item in "$@"; do [[ "$item" == "$needle" ]] && n=$((n + 1)); done
  echo "$n"
}

for want in "${REQUIRED_SECTIONS[@]}"; do
  seen=$(count_of "$want" ${SEEN_SECTIONS+"${SEEN_SECTIONS[@]}"})
  if (( seen == 0 )); then
    report "required-sections" "0" "$want" "required section is missing"
    continue
  fi
  # A duplicate heading defeats the emptiness check: content under the second
  # copy would vouch for an empty first one, and the reader hits the empty one
  # first. Reject the duplication rather than trying to decide which copy counts.
  if (( seen > 1 )); then
    report "required-sections" "0" "$want" "required section appears $seen times — one copy per document"
    continue
  fi
  if ! contains "$want" ${NONEMPTY_SECTIONS+"${NONEMPTY_SECTIONS[@]}"}; then
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

if contains "$WORKDIR_SECTION" ${SEEN_SECTIONS+"${SEEN_SECTIONS[@]}"}; then
  for anchor in "${WORKING_COPY_ANCHORS[@]}"; do
    count=$(count_of "$anchor" ${WORKING_COPY_FIELDS_SEEN+"${WORKING_COPY_FIELDS_SEEN[@]}"})
    if (( count == 0 )); then
      report "working-copy-fields" "0" "$WORKDIR_SECTION" \
        "no \"$anchor\" field — record the value or an explicit unknown/not-applicable marker"
    elif (( count > 1 )); then
      report "working-copy-fields" "0" "$WORKDIR_SECTION" \
        "\"$anchor\" appears $count times — one authoritative value is required"
    fi
  done
fi

if contains "$RESUME_SECTION" ${SEEN_SECTIONS+"${SEEN_SECTIONS[@]}"}; then
  if (( RESUME_FIELDS == 0 )); then
    report "resume-guidance" "0" "$RESUME_SECTION" \
      "no \"$RESUME_ANCHOR\" field — use /end-resume or explicitly mark a non-stop checkpoint not applicable"
  elif (( RESUME_FIELDS > 1 )); then
    report "resume-guidance" "0" "$RESUME_SECTION" \
      "\"$RESUME_ANCHOR\" appears $RESUME_FIELDS times — one authoritative command is required"
  elif (( RESUME_SEEN != 1 )); then
    report "resume-guidance" "0" "$RESUME_SECTION" \
      "invalid or empty \"$RESUME_ANCHOR\" field — use /end-resume or explicitly mark a non-stop checkpoint not applicable"
  fi
  if (( AGENT_FIELDS == 0 )); then
    report "resume-guidance" "0" "$RESUME_SECTION" \
      "no \"$AGENT_ANCHOR\" field — a different agent has no ordinary command path into the work"
  elif (( AGENT_FIELDS > 1 )); then
    report "resume-guidance" "0" "$RESUME_SECTION" \
      "\"$AGENT_ANCHOR\" appears $AGENT_FIELDS times — one authoritative command path is required"
  elif (( AGENT_SEEN != 1 )); then
    report "resume-guidance" "0" "$RESUME_SECTION" \
      "empty \"$AGENT_ANCHOR\" field — provide an ordinary command path into the work"
  fi
  (( RELAUNCH_SEEN )) || report "resume-guidance" "0" "$RESUME_SECTION" \
    "no non-empty \"$RELAUNCH_ANCHOR\" field — a takeover could duplicate already-recorded work"
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
