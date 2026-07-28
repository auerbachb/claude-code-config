#!/usr/bin/env bash
# inventory.sh — Enumerate this repo's automation surface for /harness-audit.
#
# PURPOSE
#   Emits the complete list of artifacts the harness audit must reach a verdict
#   on: the auto-loaded rule corpus, every skill, every script, and every
#   configured hook. The audit asserts `verdicts == count` per category, so
#   this script's counts are the thing that makes "no silent omissions"
#   checkable rather than merely claimed (issue #770).
#
#   It is pure enumeration. It reads no harness documentation, reaches no
#   verdict, and never writes anything outside stdout.
#
# CATEGORIES
#   rule    CLAUDE.md plus every .claude/rules/*.md — the corpus that loads on
#           every turn and is therefore under a word budget.
#   skill   Every .claude/skills/*/SKILL.md.
#   script  Every file under .claude/scripts/, excluding the lib/ and tests/
#           subtrees (helpers and test suites are not independently-earning
#           automation; they exist to serve the scripts above them).
#   hook    The union of two sources, cross-checked against each other:
#             (a) every command in global-settings.json's `hooks` map,
#             (b) every file in .claude/hooks/ (excluding lib/, tests/).
#           A hook in one source but not the other is real drift and is
#           reported in `hook_drift` as well as being inventoried.
#
# EXCLUSIONS ARE DECLARED, NEVER SILENT
#   README.md files are excluded — they document behavior rather than encode
#   it, so there is no harness default for them to be redundant with. Every
#   exclusion appears in the `exclusions` array of the output so a reader can
#   see what was skipped and why. Nothing is dropped without saying so.
#
# USAGE
#   inventory.sh [--json | --counts] [--repo-root <path>]
#   inventory.sh --help | -h
#
#   --json         Full inventory document on stdout (DEFAULT).
#   --counts       Per-category counts only, `category<TAB>count` per line.
#   --repo-root    Repo to inventory. Defaults to the enclosing git repo's
#                  top level.
#
# OUTPUT (--json)
#   {
#     "generated_at": "<ISO-8601 UTC>",
#     "repo_root": "<abs path>",
#     "counts": {"rule": N, "skill": N, "script": N, "hook": N, "total": N},
#     "artifacts": [{"category", "path", "name", ...hook-only fields}],
#     "hook_drift": [{"name", "issue", "detail"}],
#     "exclusions": [{"pattern", "reason"}]
#   }
#
#   Hook artifacts carry three extra fields: `events` (the settings.json
#   events that fire it), `in_manifest`, and `on_disk`.
#
# EXIT STATUS
#   0  Inventory emitted.
#   1  Repo root unresolvable, or a required directory is missing.
#   2  Usage error.
#
# EXAMPLES
#   .claude/skills/harness-audit/inventory.sh --counts
#   .claude/skills/harness-audit/inventory.sh | jq '.artifacts[] | select(.category=="hook")'

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "${HOME:-/tmp}/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "inventory.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE="json"
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json)    MODE="json"; shift ;;
    --counts)  MODE="counts"; shift ;;
    --repo-root)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--repo-root requires a value"
      REPO_ROOT="$2"; shift 2 ;;
    --repo-root=*)
      REPO_ROOT="${1#--repo-root=}"
      [[ -n "$REPO_ROOT" ]] || usage_error "--repo-root value cannot be empty"
      shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done

[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$REPO_ROOT" ]] || { echo "inventory.sh: not inside a git repository (pass --repo-root)" >&2; exit 1; }
fi

[[ -d "$REPO_ROOT" ]] || { echo "inventory.sh: repo root does not exist: $REPO_ROOT" >&2; exit 1; }

INVENTORY_MODE="$MODE" python3 - "$REPO_ROOT" <<'PY'
import json
import os
import sys
# timezone.utc rather than datetime.UTC: this must run on macOS system
# python3 (3.9), where datetime.UTC does not exist, and utcnow() is
# deprecation-warned on newer interpreters.
from datetime import datetime, timezone

root = os.path.abspath(sys.argv[1])
mode = os.environ.get("INVENTORY_MODE", "json")


def rel(path):
    return os.path.relpath(path, root)


def fail(msg):
    print("inventory.sh: %s" % msg, file=sys.stderr)
    sys.exit(1)


artifacts = []
exclusions = [
    {"pattern": ".claude/scripts/lib/**",
     "reason": "shared helpers — serve the scripts above them, not independent automation"},
    {"pattern": ".claude/scripts/tests/**",
     "reason": "test suites — verify the scripts, do not encode workflow behavior"},
    {"pattern": ".claude/hooks/lib/**",
     "reason": "shared hook helpers — not independently registered"},
    {"pattern": ".claude/hooks/tests/**",
     "reason": "hook test suites"},
    {"pattern": "**/README.md",
     "reason": "documentation — describes behavior rather than encoding it, so no harness default can make it redundant"},
]

# --- rules -------------------------------------------------------------------
claude_md = os.path.join(root, "CLAUDE.md")
if not os.path.isfile(claude_md):
    fail("CLAUDE.md not found at %s" % root)
artifacts.append({"category": "rule", "path": "CLAUDE.md", "name": "CLAUDE.md"})

rules_dir = os.path.join(root, ".claude", "rules")
if not os.path.isdir(rules_dir):
    fail(".claude/rules directory not found")
for entry in sorted(os.listdir(rules_dir)):
    if not entry.endswith(".md") or entry == "README.md":
        continue
    artifacts.append({
        "category": "rule",
        "path": rel(os.path.join(rules_dir, entry)),
        "name": entry,
    })

# --- skills ------------------------------------------------------------------
skills_dir = os.path.join(root, ".claude", "skills")
if not os.path.isdir(skills_dir):
    fail(".claude/skills directory not found")
for entry in sorted(os.listdir(skills_dir)):
    skill_md = os.path.join(skills_dir, entry, "SKILL.md")
    if os.path.isfile(skill_md):
        artifacts.append({
            "category": "skill",
            "path": rel(skill_md),
            "name": entry,
        })

# --- scripts -----------------------------------------------------------------
scripts_dir = os.path.join(root, ".claude", "scripts")
if not os.path.isdir(scripts_dir):
    fail(".claude/scripts directory not found")
SCRIPT_SKIP_DIRS = {"lib", "tests"}
for dirpath, dirnames, filenames in os.walk(scripts_dir):
    if dirpath == scripts_dir:
        dirnames[:] = [d for d in dirnames if d not in SCRIPT_SKIP_DIRS]
    dirnames.sort()
    for fname in sorted(filenames):
        if fname == "README.md":
            continue
        full = os.path.join(dirpath, fname)
        artifacts.append({
            "category": "script",
            "path": rel(full),
            "name": fname,
        })

# --- hooks -------------------------------------------------------------------
# Source (a): the settings manifest. Commands carry an install-time absolute
# path prefix, so match on basename — that is the stable identity.
settings_path = os.path.join(root, "global-settings.json")
manifest = {}
if os.path.isfile(settings_path):
    try:
        with open(settings_path, encoding="utf-8") as fh:
            settings = json.load(fh)
    except (json.JSONDecodeError, OSError) as exc:
        fail("cannot parse global-settings.json: %s" % exc)
    hooks_map = settings.get("hooks") or {}
    if not isinstance(hooks_map, dict):
        fail("global-settings.json 'hooks' is not an object")
    HOOKS_SEGMENT = ".claude/hooks/"
    for event, matchers in sorted(hooks_map.items()):
        for matcher in matchers or []:
            for hook in (matcher or {}).get("hooks", []) or []:
                command = str((hook or {}).get("command") or "").strip()
                if not command:
                    continue
                target = command.split()[0]
                # Key on the path *relative to .claude/hooks/* rather than the
                # bare basename, so two same-named hooks in different
                # subdirectories cannot collide into one entry. Commands carry
                # an install-time absolute prefix, so slice at the segment;
                # anything outside the hooks tree falls back to its basename.
                idx = target.find(HOOKS_SEGMENT)
                if idx >= 0:
                    key = target[idx + len(HOOKS_SEGMENT):]
                else:
                    key = os.path.basename(target)
                manifest.setdefault(key, set()).add(event)
else:
    fail("global-settings.json not found at %s" % root)

# Source (b): what is actually on disk.
hooks_dir = os.path.join(root, ".claude", "hooks")
on_disk = set()
HOOK_SKIP_DIRS = {"lib", "tests"}
if os.path.isdir(hooks_dir):
    # Walk recursively so a hook parked in a subdirectory is inventoried
    # rather than silently missed; prune only the declared exclusions. Keys
    # are paths relative to hooks_dir, matching the manifest keys above.
    for dirpath, dirnames, filenames in os.walk(hooks_dir):
        if dirpath == hooks_dir:
            dirnames[:] = [d for d in dirnames if d not in HOOK_SKIP_DIRS]
        dirnames.sort()
        for fname in sorted(filenames):
            if fname == "README.md":
                continue
            full = os.path.join(dirpath, fname)
            on_disk.add(os.path.relpath(full, hooks_dir))
else:
    fail(".claude/hooks directory not found")

hook_drift = []
for name in sorted(set(manifest) | on_disk):
    in_manifest = name in manifest
    present = name in on_disk
    artifacts.append({
        "category": "hook",
        "path": rel(os.path.join(hooks_dir, name)),
        "name": name,
        "events": sorted(manifest.get(name, [])),
        "in_manifest": in_manifest,
        "on_disk": present,
    })
    if in_manifest and not present:
        hook_drift.append({
            "name": name,
            "issue": "manifest_only",
            "detail": "registered in global-settings.json but absent from .claude/hooks/ — the hook will fail to fire",
        })
    elif present and not in_manifest:
        hook_drift.append({
            "name": name,
            "issue": "disk_only",
            "detail": "present in .claude/hooks/ but not registered in global-settings.json — dead code, a helper, or a missed registration",
        })

counts = {}
for art in artifacts:
    counts[art["category"]] = counts.get(art["category"], 0) + 1
for category in ("rule", "skill", "script", "hook"):
    counts.setdefault(category, 0)
counts["total"] = len(artifacts)

if mode == "counts":
    for category in ("rule", "skill", "script", "hook", "total"):
        sys.stdout.write("%s\t%d\n" % (category, counts[category]))
    sys.exit(0)

doc = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "repo_root": root,
    "counts": counts,
    "artifacts": artifacts,
    "hook_drift": hook_drift,
    "exclusions": exclusions,
}
sys.stdout.write(json.dumps(doc, indent=2, sort_keys=False) + "\n")
PY
