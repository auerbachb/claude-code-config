#!/usr/bin/env bash
# Lint cross-repo portability of the shared PM/orchestration skills (issue #1189).
#
# The shared PM/orchestration and stop-state skills are symlinked into every repo through
# ~/.claude/skills/, but their helper scripts and reference docs are not: most
# repos carry no .claude/ directory at all. A bare `.claude/scripts/<name>`
# invocation therefore fails silently outside this repo, and the skill degrades
# without saying so — the failure recorded in issue #1189, where a PM thread
# that could not reach its routing gate fell back to one coding-thread chip per
# ready issue, roughly twenty, with no ceiling.
#
# Validates:
#   1. No script is INVOKED by a bare `.claude/scripts/<name>` path in a
#      guarded surface. Every script name is checked, not an allow-list.
#      Candidate-list lines and prose mentions are not invocations.
#   2. Every ordered candidate list carries the skills-worktree entry, checked
#      within that list rather than anywhere in the file.
#   3. The RESOLVE block in subagent-phase-guardrails.md is byte-identical to
#      the canonical copy in portable-skill-resolution.md.
#   4. The chip `### Constraints` claim bullet in every emitter is
#      byte-identical to the canonical bullet in chip-launching.md, and that
#      bullet carries the skills-worktree candidate (a chip lands in another
#      repo, so a bare path there is the highest-impact form of this bug).
#
# Guarded surfaces:
#   .claude/skills/{pm,subagent,prompt,wave,issue-maker,start-issue,
#                   pr-monitor-and-manage,stop,stop-resume,pause,pause-resume}/
#                   (SKILL.md + references/*.md)
#   .claude/agents/*.md
#   .claude/reference/chip-launching.md
#
# Companion to chip-model-guard-lint.sh and merge-authority-lint.sh, which guard
# other literal contracts inside the same generated chip payloads.
# Paths are repo-root-relative; run from the repo root.
#
# Output uses GitHub Actions annotations (::error::) so issues surface directly
# on PR checks. Auto-discovered by run-doc-lints.sh — no workflow edit needed.
#
# Usage:
#   bash .github/scripts/skill-portability-lint.sh [--help]
#
# Exit codes:
#   0  every guarded surface is portable
#   1  one or more portability errors
#   2  usage error
#   3  a guarded surface is missing from disk — never a silent green

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: bash .github/scripts/skill-portability-lint.sh [--help]

  Verifies the shared PM/orchestration skills resolve their helper scripts and
  reference docs from any working directory, rather than through bare
  .claude/scripts/... paths that only exist in this repo (issue #1189).

  Run from the repo root. Exits 1 on any portability error, 3 if a guarded
  surface is missing from disk.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "::error::Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

SKILLS=(pm subagent prompt wave issue-maker start-issue pr-monitor-and-manage stop stop-resume pause pause-resume)

WORKTREE_PREFIX='$HOME/.claude/skills-worktree/.claude/scripts/'
CHIP_LAUNCHING=".claude/reference/chip-launching.md"
GUARDRAILS=".claude/reference/subagent-phase-guardrails.md"
CANONICAL_RESOLVE=".claude/reference/portable-skill-resolution.md"

errors=0
missing=0

err() { echo "::error::$1"; errors=$((errors + 1)); }

# --- Collect guarded files -------------------------------------------------

guarded_files=()
for skill in "${SKILLS[@]}"; do
  f=".claude/skills/${skill}/SKILL.md"
  if [[ ! -f "$f" ]]; then
    echo "::error::Guarded surface missing from disk: $f"
    missing=$((missing + 1))
    continue
  fi
  guarded_files+=("$f")
  # pr-monitor-and-manage and issue-maker split procedure text into references/
  if [[ -d ".claude/skills/${skill}/references" ]]; then
    while IFS= read -r ref; do
      guarded_files+=("$ref")
    done < <(find ".claude/skills/${skill}/references" -name '*.md' | sort)
  fi
done

# The agents directory gets the same missing-surface treatment as a SKILL.md.
# Without this, an absent .claude/agents/ made `find` emit nothing, zero agent
# definitions entered guarded_files, and the lint reported a confident pass
# having inspected none of them — the fail-open shape this lint exists to catch.
if [[ -d .claude/agents ]]; then
  agent_count=0
  while IFS= read -r agent; do
    guarded_files+=("$agent")
    agent_count=$((agent_count + 1))
  done < <(find .claude/agents -name '*.md' | sort)
  if (( agent_count == 0 )); then
    echo "::error::.claude/agents/ exists but contains no *.md — a broken glob, not an empty guard"
    missing=$((missing + 1))
  fi
else
  echo "::error::Guarded surface missing from disk: .claude/agents/"
  missing=$((missing + 1))
fi

if [[ -f "$CHIP_LAUNCHING" ]]; then
  guarded_files+=("$CHIP_LAUNCHING")
else
  echo "::error::Guarded surface missing from disk: $CHIP_LAUNCHING"
  missing=$((missing + 1))
fi

if (( missing > 0 )); then
  echo "::error::skill-portability-lint: ${missing} guarded surface(s) missing — refusing to report a pass"
  exit 3
fi

# A file present but unreadable would make every grep below return nothing,
# which is byte-identical to "this file is clean". Fail on it explicitly.
for f in "${guarded_files[@]}"; do
  if [[ ! -r "$f" ]]; then
    echo "::error::Guarded surface exists but is unreadable: $f — cannot report a pass for a file that was never inspected"
    exit 3
  fi
done

# --- Check 1 + 2: no bare invocations, and a resolver is present -----------
#
# Every `.claude/scripts/<name>` in a guarded surface is checked, not a
# maintained allow-list of "important" scripts. An allow-list is the wrong shape
# here: it silently stops covering each new helper someone adds, which is the
# same class of quiet erosion this lint exists to catch (`pr-state.sh` was
# missing from the first draft's list and its regression went undetected).
#
# A line is an INVOCATION when it reaches the path in a position that would
# execute it. Three shapes are deliberately NOT invocations:
#
#   a) a candidate-list entry — the repo-relative third entry of an ordered
#      lookup. Legitimate only when the SAME list also carries the
#      skills-worktree entry, so the check is list-scoped, not file-scoped: a
#      truncated list in a file that happens to resolve something else
#      elsewhere is exactly the silent-degradation shape, wearing the
#      resolver's clothes.
#   b) the SAFETY-block untracked-file guard (see below).
#   c) prose that names a script without running it — e.g.
#      "Use the shared helper `.claude/scripts/x.sh`".

# How far back to look for the skills-worktree sibling of a candidate entry.
# The canonical list puts it two lines above; 6 absorbs comments and wrapping.
CANDIDATE_WINDOW=6

for f in "${guarded_files[@]}"; do
  # Read the file once so a candidate entry can consult its own neighbours.
  file_lines=()
  while IFS= read -r l; do file_lines+=("$l"); done < "$f"

  while IFS= read -r hit; do
    lineno="${hit%%:*}"
    line="${hit#*:}"
    script="$(sed -E 's|.*\.claude/scripts/([A-Za-z0-9_.-]+).*|\1|' <<< "$line")"

    # Skip the worktree candidate itself and the $HOME/.claude/scripts entry.
    case "$line" in
      *skills-worktree*) continue ;;
      *'$HOME/.claude/scripts/'*) continue ;;
    esac

    # (a) Candidate-list entry: a quoted path, optionally continued.
    #     `  ".claude/scripts/foo.sh"; do` / `  ".claude/scripts/foo.sh" \`
    if [[ "$line" =~ ^[[:space:]]*\"\.claude/scripts/[A-Za-z0-9_.-]+\"[[:space:]]*(\\|\;[[:space:]]*do)?[[:space:]]*$ ]]; then
      # Look back within this list for the skills-worktree sibling.
      list_has_worktree=0
      start=$(( lineno - CANDIDATE_WINDOW )); (( start < 1 )) && start=1
      for (( i = start; i < lineno; i++ )); do
        if [[ "${file_lines[$((i - 1))]}" == *skills-worktree* ]]; then
          list_has_worktree=1
          break
        fi
      done
      if (( list_has_worktree == 0 )); then
        err "${f}:${lineno}: candidate list for ${script} has no ${WORKTREE_PREFIX} entry — a fresh repo would fall straight through to the repo-relative path"
      fi
      continue
    fi

    # (b) The SAFETY-block untracked-file guard. Its canonical source is
    #     .claude/rules/safety.md, whose verbatim copies are byte-guarded by
    #     verbatim-block-lint.sh — rewriting the path here would fight that lint
    #     and ripple into the rules corpus. It is also the one bare path that
    #     fails CLOSED: an unresolved repo-root.sh leaves $ROOT_REPO empty, git
    #     errors, no paths are emitted, and the guarded `rm` simply does not
    #     run. Safe to leave, and out of scope for #1189.
    if [[ "$line" == *"ls-files --others --exclude-standard"* ]]; then
      continue
    fi

    # (c) Prose mention: the path appears inside backticks with no argument
    #     following it, and the line is not a shell command line.
    if [[ "$line" =~ \`\.claude/scripts/[A-Za-z0-9_.-]+\`([^\`]|$) ]] \
       && [[ ! "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=?\$?\( ]] \
       && [[ ! "$line" =~ ^[[:space:]]*\.claude/scripts/ ]]; then
      continue
    fi

    err "${f}:${lineno}: bare invocation of ${script} — resolve it (skills-worktree, then \$HOME/.claude/scripts/, then repo-relative) per .claude/reference/portable-skill-resolution.md"
  # Readability was proven above, so exit 1 here genuinely means "no matches".
  # `|| true` keeps that no-match case from aborting the loop; it is not masking
  # an I/O error, which the -r pre-check already ruled out.
  done < <(grep -nE '\.claude/scripts/[A-Za-z0-9_.-]+' "$f" || true)
done

# --- Check 3: RESOLVE block is byte-identical to its canonical copy --------

extract_block() {
  # Print the block starting at the ^MARKER: line up to (excluding) the next
  # line that is exactly ```   — same anchoring convention as
  # verbatim-block-lint.sh, so the two lints agree on what a block is.
  #
  # Exit 4 when the marker is found but never closed. Without that, an
  # unterminated block runs to EOF, and two files that both lost their closing
  # fence in the same edit compare equal — a drift check passing on malformed,
  # unbounded input. An unclosed block is a parse failure, not a value.
  local marker="$1" file="$2"
  awk -v m="^${marker}:" '
    $0 ~ m { inblock = 1 }
    inblock && $0 == "```" { closed = 1; exit }
    inblock { print }
    END { if (inblock && !closed) exit 4 }
  ' "$file"
}

for f in "$CANONICAL_RESOLVE" "$GUARDRAILS"; do
  if [[ ! -f "$f" ]]; then
    echo "::error::Guarded surface missing from disk: $f"
    exit 3
  fi
done

canonical_rc=0
canonical_resolve="$(extract_block RESOLVE "$CANONICAL_RESOLVE")" || canonical_rc=$?
copy_rc=0
copy_resolve="$(extract_block RESOLVE "$GUARDRAILS")" || copy_rc=$?

if (( canonical_rc == 4 )); then
  err "${CANONICAL_RESOLVE}: RESOLVE block has no closing \`\`\` fence — cannot compare an unbounded block"
elif (( copy_rc == 4 )); then
  err "${GUARDRAILS}: RESOLVE block has no closing \`\`\` fence — cannot compare an unbounded block"
elif (( canonical_rc != 0 || copy_rc != 0 )); then
  err "extract_block failed (canonical rc=${canonical_rc}, copy rc=${copy_rc}) — refusing to treat an unread block as matching"
elif [[ -z "$canonical_resolve" ]]; then
  err "${CANONICAL_RESOLVE}: no RESOLVE: block found — the canonical copy is the edit source and must exist"
elif [[ -z "$copy_resolve" ]]; then
  err "${GUARDRAILS}: no RESOLVE: block found — phase spawn prompts would carry no resolution contract"
elif [[ "$canonical_resolve" != "$copy_resolve" ]]; then
  err "${GUARDRAILS}: RESOLVE block differs from the canonical copy in ${CANONICAL_RESOLVE} — edit the canonical file and copy it verbatim"
fi

# --- Check 4: chip claim bullet is canonical and portable -----------------

# Returns the bullet on stdout. Exit 0 = found, 1 = genuinely absent, 2 = grep
# could not read the file. The caller must not collapse 1 and 2: "this skill has
# no claim bullet" and "we never looked" are different facts, and treating the
# second as the first is how a drift check silently stops checking.
claim_bullet() {
  grep -m1 -F -- '- Claim the issue before anything else' "$1"
}

canonical_claim_rc=0
canonical_claim="$(claim_bullet "$CHIP_LAUNCHING")" || canonical_claim_rc=$?

if (( canonical_claim_rc > 1 )); then
  err "${CHIP_LAUNCHING}: could not be read while looking for the canonical claim bullet (grep exit ${canonical_claim_rc})"
elif [[ -z "$canonical_claim" ]]; then
  err "${CHIP_LAUNCHING}: canonical Form A claim bullet not found"
elif [[ "$canonical_claim" != *"$WORKTREE_PREFIX"issue-claim.sh* ]]; then
  err "${CHIP_LAUNCHING}: the claim bullet does not carry the skills-worktree candidate — a generated chip runs in another repo, where a bare .claude/scripts path does not exist"
else
  for skill in pm prompt wave issue-maker; do
    f=".claude/skills/${skill}/SKILL.md"
    bullet_rc=0
    bullet="$(claim_bullet "$f")" || bullet_rc=$?
    if (( bullet_rc > 1 )); then
      err "${f}: could not be read while looking for the claim bullet (grep exit ${bullet_rc}) — an unread file is not a clean one"
      continue
    fi
    # Exit 1 (genuinely absent) is not a failure: /start-issue carries Form B
    # instead, and /wave reuses /pm's template wholesale rather than duplicating
    # the bullet. Whether an emitter must carry Constraints content at all is
    # merge-authority-lint.sh's question, not this lint's.
    (( bullet_rc == 1 )) && continue
    if [[ "$bullet" != "$canonical_claim" ]]; then
      err "${f}: claim bullet differs from the canonical copy in ${CHIP_LAUNCHING} — reproduce it verbatim"
    fi
  done
fi

# --- Result ---------------------------------------------------------------

if (( errors > 0 )); then
  echo "skill-portability-lint: ${errors} error(s) found" >&2
  exit 1
fi

echo "skill-portability-lint: OK (${#guarded_files[@]} guarded surfaces)"
exit 0
