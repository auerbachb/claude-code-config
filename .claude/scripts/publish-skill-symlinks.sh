#!/bin/bash
# publish-skill-symlinks.sh — Publish the skill / CLAUDE.md / rules symlinks
# from the skills worktree into ~/.claude/.
#
# Extracted from setup-skills-worktree.sh Steps 3, 3b, 4 and 5 (issue #1524) so
# that a steady-state pass — the scheduled claude-config-sync.sh tick, or a
# session-start hook — can link newly merged skills without re-running the full
# bootstrap. Mirrors publish-agent-symlinks.sh, which did the same for the
# agents leg in issue #1197.
#
# Usage: publish-skill-symlinks.sh <skills-worktree> [<repo-root>]
#
# ARGUMENTS
#   skills-worktree  Absolute path to ~/.claude/skills-worktree
#   repo-root        (optional) Root repo path; used only to recognise legacy
#                    root-repo symlinks that pre-date the worktree topology and
#                    should be migrated. Pass "" or omit when unknown — the
#                    script still publishes all worktree-backed symlinks.
#
# WHAT IT PUBLISHES
#   ~/.claude/skills/<name>  ->  <worktree>/.claude/skills/<name>   (per-entry)
#   ~/.claude/CLAUDE.md      ->  <worktree>/CLAUDE.md
#   ~/.claude/rules          ->  <worktree>/.claude/rules           (directory)
#
#   The skills leg is a REAL directory holding one symlink per skill; `rules` is
#   a single directory symlink. That asymmetry is deliberate and documented in
#   ARCHITECTURE.md §Skills Worktree — do not "unify" it here.
#
# OUTPUT
#   Stdout:  One line per CHANGE (created, updated, migrated, pruned). A run that
#            changed nothing prints nothing on stdout, so callers may use stdout
#            presence as a change signal.
#   Stderr:  Warnings and advisory notices for non-fatal conditions — a
#            user-owned symlink left alone, a legacy link whose target is not on
#            main yet, a non-symlink that will not be overwritten. These are
#            steady-state facts, not changes, so they stay off stdout; each is
#            reported at most ONCE per link per run.
#
# EXIT CODES
#   0  Success, including when the worktree has no .claude/skills/ directory
#   1  Unexpected failure (a symlink could not be created or removed)
#   2  Usage error (no skills-worktree argument)
#
# OWNERSHIP — what is preserved, and what is not
#   SKILLS: a `~/.claude/skills/<name>` symlink pointing outside the worktree
#   (and outside the legacy root-repo skills directory) is the user's personal
#   skill. It is never repointed and never pruned — the ownership rule from
#   PR #1196.
#
#   CLAUDE.md AND rules: these are NOT user-owned. This repo is their single
#   source of truth (.claude/rules/skill-symlinks.md), so a symlink pointing
#   anywhere else is repointed at the worktree — that migration is the whole
#   reason the leg exists. What IS preserved either way is a REGULAR FILE or
#   directory at those paths: hand-authored content is warned about and never
#   overwritten.
#
# Idempotent — safe to run every session and on every scheduled tick.
#
# DEPENDENCIES
#   bash, ln, rm, readlink, basename, python3 (path normalisation only)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: publish-skill-symlinks.sh <skills-worktree> [<repo-root>]

  Publishes the skill, CLAUDE.md and rules symlinks from the skills worktree
  into ~/.claude/. Idempotent; a no-op run prints nothing.

  skills-worktree  Absolute path to ~/.claude/skills-worktree
  repo-root        Optional root repo path, used only to recognise and migrate
                   legacy root-repo symlinks.

  Exit 0 success, 1 a symlink could not be created or removed, 2 usage error.
EOF
}

# Argument-count guard FIRST, so a zero-argument call exits through the
# documented usage path before anything iterates "$@".
if [[ $# -lt 1 ]]; then
  echo "publish-skill-symlinks.sh: SKILLS_WORKTREE argument not provided" >&2
  usage >&2
  exit 2
fi

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

if [[ -z "${1:-}" ]]; then
  echo "publish-skill-symlinks.sh: SKILLS_WORKTREE argument is empty" >&2
  usage >&2
  exit 2
fi

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# _normpath <path> — os.path.normpath on stdout: trailing slashes stripped,
# interior `//` collapsed, `..` resolved, without requiring the path to exist.
# Returns NON-ZERO and prints nothing when python3 cannot run, so each caller
# picks its own posture for "cannot normalize" — the two here differ on purpose.
_normpath() {
  python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]))" "$1" 2>/dev/null
}

# One-time probe distinguishing the two reasons _normpath can fail, which need
# opposite postures:
#
#   TOOL MISSING  — python3 absent or broken. Affects every path equally, so it
#                   says nothing about any individual path. Normalizing neither
#                   side is self-consistent (both stay raw) and preserves the
#                   plain prefix comparison the callers below rely on.
#   PATH REJECTED — python3 works but choked on this one argument. That IS a
#                   statement about the path, and the safe answer is "not ours".
#
# Without this split, a python3-less machine classified EVERY managed symlink as
# user-owned: normalize_arg kept the raw prefix while skill_owned_by_setup hard
# -failed, so the publish silently degraded to a no-op on existing links, the
# prune loop stopped pruning, and each link drew a "leaving user-owned symlink
# alone" advisory that was simply untrue. The probe uses a literal already
# -normal path, so a working python3 always returns it unchanged.
_NORMPATH_OK=1
if [[ "$(_normpath /tmp)" != "/tmp" ]]; then
  _NORMPATH_OK=0
  echo "  WARNING: python3 unavailable — symlink targets cannot be normalized;" >&2
  echo "           falling back to raw path comparison for this run." >&2
fi

# Arguments are normalized the SAME way symlink targets are below. A prefix
# built from ".../skills-worktree/" or ".../a//b" would never match a normalized
# target, so every managed link would be misread as user-owned and the publish
# would silently do nothing. Posture on failure: keep the raw value — an
# unnormalized prefix is no worse than never normalizing at all.
normalize_arg() {
  local raw="$1" out
  [[ -n "$raw" ]] || { printf ''; return 0; }
  out="$(_normpath "$raw")" || out="$raw"
  printf '%s' "$out"
}

SKILLS_WORKTREE="$(normalize_arg "$1")"
REPO_ROOT="$(normalize_arg "${2:-}")"
SKILLS_DIR="$HOME/.claude/skills"
WORKTREE_SKILLS="$SKILLS_WORKTREE/.claude/skills"

# --- Helper: migrate_symlink ---
# --- Helper: relink_atomic ---
# Repoint an EXISTING symlink at a new target without ever unlinking it first.
#
# `rm "$link"; ln -s "$new" "$link"` leaves a window in which the path does not
# exist at all. Every managed link here is one a live session reads directly —
# ~/.claude/CLAUDE.md, ~/.claude/rules, ~/.claude/skills/<name> — so a session
# starting inside that window loads a config with no rules, or silently misses a
# skill. Building the replacement at a sibling temp path and renaming it over
# the old one closes the window: rename(2) is atomic, so a reader sees either
# the old target or the new one, never nothing. The temp name stays in the
# link's own directory because rename cannot cross filesystems.
#
# The flag matters and is NOT cosmetic. Most links here point at DIRECTORIES,
# and a bare `mv tmp link` on a symlink-to-directory follows it and drops the
# temp link INSIDE the target directory instead of replacing the link — silent
# and wrong. BSD/macOS spells "don't follow" as -h, GNU spells it -T; they are
# tried in turn rather than probed, since an unrecognized flag is a usage error
# that changes nothing. If neither is understood we fall back to the original
# non-atomic replace rather than skipping the update entirely.
relink_atomic() { # relink_atomic LINK TARGET
  local link="$1" target="$2" tmp
  tmp="${link}.tmp.$$-${RANDOM}"
  ln -s "$target" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; rm "$link" && ln -s "$target" "$link"; return; }
  if mv -h "$tmp" "$link" 2>/dev/null || mv -T "$tmp" "$link" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  rm "$link" && ln -s "$target" "$link"
}

# Manages one symlink, handling all five states:
#   already-correct target   → no-op (silent)
#   legacy LEGACY_TARGET     → migrate if NEW_TARGET exists; warn if not
#   any other symlink target → repoint to NEW_TARGET
#   non-symlink regular file → warn, never overwrite
#   missing                  → create if NEW_TARGET passes EXISTENCE_TEST
#
# Usage: migrate_symlink LINK NEW_TARGET LEGACY_TARGET LABEL EXISTENCE_TEST
#   LEGACY_TARGET may be empty to skip the legacy-migration branch.
migrate_symlink() {
  local link="$1" new_target="$2" legacy_target="$3" label="$4" existence_test="$5"

  if [[ -L "$link" ]]; then
    local current_target
    current_target="$(readlink "$link")"
    if [[ "$current_target" == "$new_target" ]]; then
      : # already correct — silent no-op
    elif [[ -n "$legacy_target" && "$current_target" == "$legacy_target" ]]; then
      if test "$existence_test" "$new_target"; then
        echo "  $label — migrating from root repo to worktree"
        relink_atomic "$link" "$new_target"
      else
        echo "  $label — WARNING: legacy root-repo symlink exists but target not in worktree (not on main yet)" >&2
      fi
    else
      echo "  $label — updating symlink (was: $current_target)"
      relink_atomic "$link" "$new_target"
    fi
  elif [[ -e "$link" ]]; then
    echo "  WARNING: $link is not a symlink — skipping (will not overwrite)" >&2
  else
    if test "$existence_test" "$new_target"; then
      echo "  $label — creating"
      ln -s "$new_target" "$link"
    fi
  fi
}

# --- Helper: skill_owned_by_setup ---
# Returns true (exit 0) when the symlink target is one this script manages —
# i.e., it points into the skills worktree or into the legacy root-repo skills
# directory that is being migrated away from. Used by both the publish and prune
# loops to leave user-owned personal skills untouched (mirrors the identical
# predicate in publish-agent-symlinks.sh for the agents leg).
#
# The target is normalized before the prefix check so that traversal sequences
# (e.g. ~/.claude/skills-worktree/../../../etc) cannot cause a path outside the
# managed directories to be misidentified as setup-owned.
# Posture on failure differs from normalize_arg above, deliberately: when the
# normalizer IS available and rejects this particular TARGET, return 1 — "not
# ours" — so the link is left alone. Declining to touch something we cannot
# classify is the safe error there.
#
# That posture applies ONLY to a per-path rejection. When _NORMPATH_OK is 0 the
# normalizer is missing outright (see the probe above): every path is equally
# un-normalizable, the prefixes built by normalize_arg are equally raw, and
# refusing to classify would disable the whole publish rather than protect
# anything. Compare raw against raw in that case.
skill_owned_by_setup() {
  local raw_target="$1"
  local candidate target
  if [[ "$raw_target" == /* ]]; then
    candidate="$raw_target"
  else
    # Relative symlinks are rare (all setup-created links are absolute) but resolve
    # them against SKILLS_DIR — the parent directory of every skill symlink.
    candidate="$SKILLS_DIR/$raw_target"
  fi
  if (( _NORMPATH_OK == 1 )); then
    target="$(_normpath "$candidate")" || return 1
  else
    target="$candidate"
  fi
  [[ "$target" == "$WORKTREE_SKILLS/"* ]] && return 0
  [[ -n "$REPO_ROOT" && "$target" == "$REPO_ROOT/.claude/skills/"* ]] && return 0
  return 1
}

mkdir -p "$SKILLS_DIR"

# --- Step 1: Publish one symlink per skill in the worktree ---

if [[ ! -d "$WORKTREE_SKILLS" ]]; then
  echo "  WARNING: no .claude/skills/ directory in $SKILLS_WORKTREE — skipping skill symlinks" >&2
else
  for skill_dir in "$WORKTREE_SKILLS"/*/; do
    # Skip if the glob matched nothing.
    [[ -d "$skill_dir" ]] || continue

    skill_name="$(basename "$skill_dir")"
    # Defensive: a name that is empty or carries a path separator would make the
    # directory-copy replacement below reach outside ~/.claude/skills/.
    [[ -n "$skill_name" && "$skill_name" != *"/"* && "$skill_name" != "." && "$skill_name" != ".." ]] || continue

    target="$WORKTREE_SKILLS/$skill_name"
    link="$SKILLS_DIR/$skill_name"

    if [[ -L "$link" ]]; then
      current_target="$(readlink "$link")"
      if [[ "$current_target" == "$target" ]]; then
        continue  # already correct — silent no-op
      fi
      # A link pointing somewhere we do not manage is a user-owned personal
      # skill. Leave it alone rather than silently repointing it. Worth saying
      # out loud — the worktree carries a skill of the same name, so the user's
      # copy is shadowing it — but it is a standing condition, not a change,
      # so it goes to stderr. The prune loop below will not repeat it.
      if ! skill_owned_by_setup "$current_target"; then
        echo "  $skill_name — leaving user-owned symlink alone (-> $current_target)" >&2
        continue
      fi
      echo "  $skill_name — updating symlink (was: $current_target)"
      rm "$link"
    elif [[ -d "$link" ]]; then
      # A real directory here is a pre-worktree COPY of the skill. Replacing it
      # is the documented migration (see .claude/rules/skill-symlinks.md); the
      # name guard above keeps the removal inside ~/.claude/skills/.
      echo "  $skill_name — replacing directory copy with symlink"
      rm -rf "$link"
    elif [[ -e "$link" ]]; then
      echo "  WARNING: $link is not a symlink or directory — skipping (will not overwrite)" >&2
      continue
    fi

    ln -s "$target" "$link"
    echo "  $skill_name — symlinked"
  done

  # --- Step 2: Prune orphaned skill symlinks (skill renamed or removed on main) ---
  # Glob without a trailing slash so dangling symlinks are included — a broken
  # link is not a directory, so a */-style glob would skip it.
  # Only setup-managed links are pruned; user-owned personal skills stay.
  for link in "$SKILLS_DIR"/*; do
    [[ -e "$link" || -L "$link" ]] || continue
    [[ -L "$link" ]] || continue
    skill_name="$(basename "$link")"
    current_target="$(readlink "$link")"
    if ! skill_owned_by_setup "$current_target"; then
      # Report only what the publish loop above did not: that loop already named
      # every user-owned link whose name also exists in the worktree.
      if [[ ! -d "$WORKTREE_SKILLS/$skill_name" ]]; then
        echo "  $skill_name — leaving user-owned symlink alone (-> $current_target)" >&2
      fi
      continue
    fi
    # Skip legacy root-repo links: Step 3 migrates them via migrate_symlink,
    # which preserves the link and warns when the worktree target does not yet
    # exist (skill not on main). Pruning here would remove it first.
    if [[ -n "$REPO_ROOT" && "$current_target" == "$REPO_ROOT/.claude/skills/$skill_name" ]]; then
      continue
    fi
    if [[ ! -d "$WORKTREE_SKILLS/$skill_name" ]]; then
      echo "  $skill_name — removing stale symlink (no matching skill in worktree)"
      rm "$link" || echo "  WARNING: could not remove $link — remove it manually" >&2
    fi
  done

  # --- Step 3: Migrate symlinks still pointing at the old root-repo location ---

  if [[ -n "$REPO_ROOT" ]]; then
    for link in "$SKILLS_DIR"/*; do
      [[ -e "$link" || -L "$link" ]] || continue
      [[ -L "$link" ]] || continue
      skill_name="$(basename "$link")"
      current_target="$(readlink "$link")"
      if [[ "$current_target" == "$REPO_ROOT/.claude/skills/$skill_name" ]]; then
        migrate_symlink "$link" "$WORKTREE_SKILLS/$skill_name" \
          "$REPO_ROOT/.claude/skills/$skill_name" "$skill_name" -d
      fi
    done
  fi
fi

# --- Step 4: CLAUDE.md and rules ---
#
# No ownership check here, deliberately: unlike a personal skill, `~/.claude/
# CLAUDE.md` and `~/.claude/rules` have exactly one correct target, and
# repointing a symlink that drifted elsewhere is the migration this leg exists
# to perform (.claude/rules/skill-symlinks.md). migrate_symlink still refuses to
# touch a regular file or directory at either path.

CLAUDE_MD_LINK="$HOME/.claude/CLAUDE.md"
CLAUDE_MD_TARGET="$SKILLS_WORKTREE/CLAUDE.md"
RULES_LINK="$HOME/.claude/rules"
RULES_TARGET="$SKILLS_WORKTREE/.claude/rules"

legacy_claude_md=""
legacy_rules=""
if [[ -n "$REPO_ROOT" ]]; then
  legacy_claude_md="$REPO_ROOT/CLAUDE.md"
  legacy_rules="$REPO_ROOT/.claude/rules"
fi

migrate_symlink "$CLAUDE_MD_LINK" "$CLAUDE_MD_TARGET" "$legacy_claude_md" "CLAUDE.md" -f
migrate_symlink "$RULES_LINK" "$RULES_TARGET" "$legacy_rules" "rules" -d
