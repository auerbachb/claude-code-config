#!/usr/bin/env python3
# catalog: utilities — Memory-store audit engine behind `/memory-clean`
"""memory-audit.py — audit + guarded prune for the durable memory store (issue #620).

The memory store lives at ``~/.claude/projects/<encoded-project>/memory/``: one
fact per ``*.md`` file plus a ``MEMORY.md`` index (``- [Title](file.md) — hook``
per line) that is read into context every session. Over time it drifts —
superseded facts, index pointers to deleted files, and ``.md`` files no longer
referenced by the index. This script is the engine behind the ``/memory-clean``
skill: it DETECTS drift (``--check``) and, only when handed an explicit list of
files, performs a boundary-guarded atomic PRUNE (``--apply``) that rewrites the
index and verifies integrity.

Design (mirrors the ticket's "lean conservative" guidance):
  High-confidence categories, surfaced with recommendations:
    - orphaned files   : a ``*.md`` on disk with no ``MEMORY.md`` pointer
                         (REPORT-ONLY — deletion is strictly opt-in; some
                         orphans are intentionally unindexed)
    - dangling pointers: a ``MEMORY.md`` link whose target file is missing
    - index health     : entry count + index byte size vs a soft budget
  Advisory-only category (never auto-recommended), each citing its replacement:
    - duplicate frontmatter ``name:`` across two files
    - a supersede marker (``superseded by`` / ``replaced by`` / ``deprecated`` /
      ``obsolete``) CONJOINED WITH a ``[[slug]]`` or ``*.md`` cross-reference.
      Bare keyword matches are excluded on purpose — a naive scan mislabels a
      memory whose text merely discusses superseding (e.g. "does not supersede").

Safety (deletes are irreversible):
  - the resolved dir must look like a memory store (named ``memory`` or holding a
    ``MEMORY.md``) and is refused if it is ``/``, ``$HOME``, ``~/.claude`` or
    ``~/.claude/projects``;
  - the file scan skips symlinks, so nothing outside the store is ever read;
  - every delete target must be a bare ``*.md`` basename (never ``MEMORY.md``),
    must resolve to a DIRECT CHILD of the memory dir (symlink escapes rejected),
    and is re-checked immediately before ``unlink`` (TOCTOU);
  - the index is rewritten atomically (temp in the same dir + ``os.replace``)
    BEFORE any file is deleted, so a write failure aborts with zero mutation and
    a failed deletion leaves a safe orphan, never a dangling pointer;
  - after pruning, the run FAILS if it created any new dangling pointer.

Usage:
  memory-audit.py --check [--dir DIR] [--json] [--budget-bytes N]
  memory-audit.py --apply --files "a.md,b.md" [--drop-index "x.md"]
                  [--dir DIR] [--json] [--budget-bytes N]

  --dir DIR         Target memory dir. Default: auto-detect from the current
                    git repo — the ROOT project (parent of ``--git-common-dir``),
                    path-encoded, under ``~/.claude/projects/``. Auto-detect
                    deliberately uses the root project, not the worktree, because
                    memory is pinned to the root project across worktree sessions.
  --check           Read-only detection (default when neither mode is given).
  --apply           Perform the prune. Requires --files and/or --drop-index.
  --files LIST      Comma-separated bare ``*.md`` basenames to DELETE (and whose
                    index lines are dropped). Each must exist in the memory dir.
  --drop-index LIST Comma-separated bare ``*.md`` basenames whose index lines are
                    dropped WITHOUT deleting a file — for clearing dangling
                    pointers (the file is already gone).
  --json            Emit a JSON object on stdout instead of human text.
  --budget-bytes N  Index size soft budget. Default 24576 (24 KB) — the index is
                    read into context every session; ~24 KB is the observed soft
                    read limit.

Exit codes:
  0  OK (including "nothing flagged" and a clean prune)
  2  usage error
  3  environment error (memory dir not found / not a directory)
  4  safety refusal, post-prune integrity failure, or an unexpected filesystem /
     runtime error (validation happens before any delete; the index is rewritten
     before any unlink, so a failure never leaves a dangling pointer)

Unit tests: tests/test_memory_audit.py (wired into .github/workflows/hook-scripts.yml).
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

MEMORY_INDEX = "MEMORY.md"
DEFAULT_BUDGET_BYTES = 24576  # 24 KB soft read budget (index loads every session)

# First markdown link on a line whose target we treat as the index pointer.
_LINK_RE = re.compile(r"\]\(([^)]+)\)")
# "This entry is stale" markers — deliberately NOT bare "supersede(s)", which is
# usually descriptive prose rather than a self-staleness flag.
_STALE_MARKER_RE = re.compile(
    r"\b(superseded by|replaced by|deprecated|obsolete|no longer needed)\b",
    re.IGNORECASE,
)
_WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
_MDFILE_RE = re.compile(r"([A-Za-z0-9._-]+\.md)")


def _log_invocation(argv: List[str]) -> None:
    """Best-effort usage log, matching the repo's shell-script convention."""
    try:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = "{}\t{}\t{}\n".format(stamp, os.path.basename(__file__), " ".join(argv))
        with open(os.path.expanduser("~/.claude/script-usage.log"), "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


class AuditError(Exception):
    """Carries an exit code alongside the message."""

    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------- #
# Directory resolution + safety guard
# --------------------------------------------------------------------------- #

def encode_project_path(path: str) -> str:
    """Encode an absolute project path the way Claude Code names project dirs:
    every ``/`` and ``.`` becomes ``-`` (1:1, no run collapsing)."""
    return re.sub(r"[/.]", "-", path)


def autodetect_memory_dir() -> Optional[str]:
    """Best-effort: current git repo's ROOT project (parent of --git-common-dir),
    path-encoded, under ~/.claude/projects/. Returns None if it can't be found."""
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True,
        )
        common_dir = common.stdout.strip() if common.returncode == 0 else ""
        if not common_dir:
            # Fallback for git < 2.31 (no --path-format): resolve relative output.
            alt = subprocess.run(
                ["git", "rev-parse", "--git-common-dir"],
                capture_output=True, text=True,
            )
            if alt.returncode != 0 or not alt.stdout.strip():
                return None
            common_dir = os.path.realpath(alt.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        return None
    root = os.path.dirname(os.path.realpath(common_dir))
    candidate = os.path.expanduser(
        os.path.join("~/.claude/projects", encode_project_path(root), "memory")
    )
    return candidate if os.path.isdir(candidate) else None


def resolve_memory_dir(dir_arg: Optional[str]) -> str:
    """Resolve and guard the target memory dir. Raises AuditError on any problem."""
    if dir_arg:
        target = os.path.abspath(os.path.expanduser(dir_arg))
        if not os.path.isdir(target):
            raise AuditError("memory dir not found: {}".format(target), 3)
    else:
        auto = autodetect_memory_dir()
        if not auto:
            raise AuditError(
                "could not auto-detect the memory dir; pass --dir explicitly", 3
            )
        target = os.path.abspath(auto)

    real = os.path.realpath(target)
    home = os.path.realpath(os.path.expanduser("~"))
    forbidden = {
        os.path.realpath(os.sep),
        home,
        os.path.join(home, ".claude"),
        os.path.join(home, ".claude", "projects"),
    }
    if real in forbidden:
        raise AuditError("refusing to operate on a non-memory directory: {}".format(real), 4)
    # Must look like a memory store: named `memory` OR holding a MEMORY.md.
    if os.path.basename(real) != "memory" and not os.path.isfile(
        os.path.join(real, MEMORY_INDEX)
    ):
        raise AuditError(
            "not a memory store (no {} and dir is not named 'memory'): {}".format(
                MEMORY_INDEX, real
            ),
            4,
        )
    return real


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #

def list_memory_files(mem_dir: str) -> List[str]:
    """Sorted basenames of top-level regular ``*.md`` files, excluding the index.

    Symlinks are skipped: a symlink could point outside the store, and reading
    it during advisory parsing would violate the boundary guarantee (and it is
    never a real one-fact memory file). This keeps the scan — like the delete
    path — strictly inside the memory dir."""
    out = []
    for name in os.listdir(mem_dir):
        if not name.endswith(".md") or name == MEMORY_INDEX:
            continue
        p = os.path.join(mem_dir, name)
        if os.path.islink(p):
            continue
        if os.path.isfile(p):
            out.append(name)
    return sorted(out)


def extract_pointer(line: str) -> Optional[str]:
    """First markdown-link target on the line that ends in ``.md`` (basename)."""
    for target in _LINK_RE.findall(line):
        t = target.strip()
        if t.endswith(".md") and "://" not in t:
            return os.path.basename(t)
    return None


def parse_index(mem_dir: str) -> Tuple[str, bool, List[str], List[Tuple[int, str]]]:
    """Return (index_path, exists, raw_lines, pointers) where pointers is a list
    of (line_index, target_basename) for every index line carrying a pointer."""
    index_path = os.path.join(mem_dir, MEMORY_INDEX)
    if not os.path.isfile(index_path):
        return index_path, False, [], []
    with open(index_path, "r", encoding="utf-8") as fh:
        content = fh.read()
    raw_lines = content.splitlines()
    pointers = []
    for i, line in enumerate(raw_lines):
        ptr = extract_pointer(line)
        if ptr is not None:
            pointers.append((i, ptr))
    return index_path, True, raw_lines, pointers


def read_frontmatter_name(path: str) -> Optional[str]:
    """Extract the top-level ``name:`` value from a file's YAML frontmatter."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
            if first.strip() != "---":
                return None
            for line in fh:
                if line.strip() == "---":
                    return None
                if line.startswith("name:"):
                    return line[len("name:"):].strip() or None
    except OSError:
        return None
    return None


def detect_superseded(mem_dir: str, files: List[str]) -> List[Dict[str, str]]:
    """Advisory, conservative: a stale marker CONJOINED WITH a cross-reference
    that names the replacement. Bare keyword hits are intentionally ignored."""
    flags = []
    for name in files:
        path = os.path.join(mem_dir, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        marker = _STALE_MARKER_RE.search(text)
        if not marker:
            continue
        replacement = None
        wl = _WIKILINK_RE.search(text)
        if wl:
            replacement = wl.group(1).strip()
        else:
            for cand in _MDFILE_RE.findall(text):
                if cand != name and cand != MEMORY_INDEX:
                    replacement = cand
                    break
        if replacement is None:
            continue  # marker without a named replacement → too low-confidence
        flags.append(
            {
                "file": name,
                "marker": marker.group(1).lower(),
                "replacement": replacement,
            }
        )
    return flags


def detect_duplicate_names(mem_dir: str, files: List[str]) -> List[Dict[str, object]]:
    """Advisory: two files sharing a frontmatter ``name:`` value."""
    by_name: Dict[str, List[str]] = {}
    for name in files:
        fm = read_frontmatter_name(os.path.join(mem_dir, name))
        if not fm:
            continue
        by_name.setdefault(fm.lower(), []).append(name)
    dups = []
    for _, group in sorted(by_name.items()):
        if len(group) > 1:
            fm_display = read_frontmatter_name(os.path.join(mem_dir, group[0])) or group[0]
            dups.append({"name": fm_display, "files": sorted(group)})
    return dups


# --------------------------------------------------------------------------- #
# Detection (--check)
# --------------------------------------------------------------------------- #

def detect(mem_dir: str, budget_bytes: int) -> Dict[str, object]:
    files = list_memory_files(mem_dir)
    index_path, exists, _raw, pointers = parse_index(mem_dir)

    referenced = set(ptr for _, ptr in pointers)
    file_set = set(files)
    orphans = sorted(file_set - referenced)
    dangling = sorted(referenced - file_set)

    index_bytes = os.path.getsize(index_path) if exists else 0
    entry_count = len(pointers)

    superseded = detect_superseded(mem_dir, files)
    duplicate_names = detect_duplicate_names(mem_dir, files)

    return {
        "memory_dir": mem_dir,
        "index": {
            "path": index_path,
            "exists": exists,
            "bytes": index_bytes,
            "entry_count": entry_count,
            "file_count": len(files),
            "budget_bytes": budget_bytes,
            "over_budget": index_bytes > budget_bytes,
        },
        "orphans": orphans,
        "dangling": dangling,
        "advisory": {
            "duplicate_names": duplicate_names,
            "superseded": superseded,
        },
        "summary": {
            "orphan_count": len(orphans),
            "dangling_count": len(dangling),
            "advisory_count": len(superseded) + len(duplicate_names),
            "over_budget": index_bytes > budget_bytes,
        },
    }


# --------------------------------------------------------------------------- #
# Prune (--apply)
# --------------------------------------------------------------------------- #

def _validate_basename(name: str) -> str:
    name = name.strip()
    if not name:
        raise AuditError("empty filename in list", 2)
    if name != os.path.basename(name) or name in (".", "..") or "\\" in name:
        raise AuditError("refusing path with a directory component: {}".format(name), 4)
    if not name.endswith(".md"):
        raise AuditError("refusing non-.md target: {}".format(name), 4)
    if name == MEMORY_INDEX:
        raise AuditError("refusing to delete the index {}".format(MEMORY_INDEX), 4)
    return name


def _resolve_child(mem_dir: str, name: str) -> str:
    """Absolute path of ``name`` verified to be a direct child of ``mem_dir``
    (symlink escapes rejected). Existence is checked by the caller."""
    p = os.path.join(mem_dir, name)
    rp = os.path.realpath(p)
    if os.path.dirname(rp) != os.path.realpath(mem_dir):
        raise AuditError("refusing target outside the memory dir: {}".format(name), 4)
    return p


def _atomic_write(path: str, content: str) -> None:
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".MEMORY-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply_prune(
    mem_dir: str,
    delete_files: List[str],
    drop_index: List[str],
    budget_bytes: int,
) -> Dict[str, object]:
    if not delete_files and not drop_index:
        raise AuditError("--apply requires --files and/or --drop-index", 2)

    # --- validate everything BEFORE touching the filesystem ---
    delete_set = [_validate_basename(n) for n in delete_files]
    drop_set = [_validate_basename(n) for n in drop_index]

    before = detect(mem_dir, budget_bytes)
    dangling_before = set(before["dangling"])

    resolved = []
    for name in delete_set:
        p = _resolve_child(mem_dir, name)
        if not os.path.isfile(p):
            raise AuditError("delete target not found: {}".format(name), 4)
        resolved.append((name, p))

    # drop-index targets must currently be dangling (no such file). Deleting a
    # live file's line without deleting the file would CREATE a dangling pointer.
    for name in drop_set:
        if os.path.isfile(os.path.join(mem_dir, name)):
            raise AuditError(
                "--drop-index target {} still has a file; pass it via --files "
                "to delete the file, or remove it from --drop-index".format(name),
                4,
            )

    # --- rewrite the index FIRST (drop lines whose pointer is deleted/dropped) ---
    # Ordering matters: if the atomic index write fails, we abort here having
    # deleted NOTHING. And if a later file deletion fails, the store is left with
    # a safe orphan (a file with no pointer), never a dangling pointer. This makes
    # the operation fail toward the safe direction even without a true transaction.
    drop_pointers = set(delete_set) | set(drop_set)
    index_path, exists, raw_lines, _ptrs = parse_index(mem_dir)
    dropped_lines = []
    kept = []
    if exists and drop_pointers:
        for line in raw_lines:
            ptr = extract_pointer(line)
            if ptr is not None and ptr in drop_pointers:
                dropped_lines.append(line)
            else:
                kept.append(line)
    # Only rewrite when we actually remove lines — deleting an unindexed orphan
    # must leave MEMORY.md byte-identical.
    if dropped_lines:
        # Preserve the original trailing-newline shape.
        with open(index_path, "r", encoding="utf-8") as fh:
            had_trailing_nl = fh.read().endswith("\n")
        new_content = "\n".join(kept)
        if had_trailing_nl and new_content:
            new_content += "\n"
        _atomic_write(index_path, new_content)

    # --- delete the files (TOCTOU re-check right before each unlink) ---
    deleted = []
    delete_failures = []
    for name, path in resolved:
        rp = os.path.realpath(path)
        if os.path.dirname(rp) != os.path.realpath(mem_dir) or not os.path.isfile(rp):
            delete_failures.append(name)
            continue
        try:
            os.unlink(path)
            deleted.append(name)
        except OSError:
            delete_failures.append(name)

    # --- integrity verification ---
    after = detect(mem_dir, budget_bytes)
    dangling_after = set(after["dangling"])
    new_dangling = sorted(dangling_after - dangling_before)
    remaining_orphans = list(after["orphans"])
    remaining_dangling = sorted(dangling_after)

    ok = not new_dangling and not delete_failures
    result = {
        "memory_dir": mem_dir,
        "deleted": deleted,
        "delete_failures": delete_failures,
        "index_lines_dropped": dropped_lines,
        "before": {
            "entry_count": before["index"]["entry_count"],
            "bytes": before["index"]["bytes"],
        },
        "after": {
            "entry_count": after["index"]["entry_count"],
            "bytes": after["index"]["bytes"],
        },
        "integrity": {
            "ok": ok,
            "new_dangling": new_dangling,
            "remaining_dangling": remaining_dangling,
            "remaining_orphans": remaining_orphans,
        },
    }
    if new_dangling:
        raise AuditError(
            "integrity check FAILED — prune created dangling pointers: {}".format(
                ", ".join(new_dangling)
            ),
            4,
        )
    if delete_failures:
        raise AuditError(
            "index updated, but these files could not be deleted (now unindexed "
            "orphans, safe to retry): {}".format(", ".join(delete_failures)),
            4,
        )
    return result


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #

def _render_check(r: Dict[str, object]) -> str:
    idx = r["index"]
    adv = r["advisory"]
    lines = []
    lines.append("Memory store: {}".format(r["memory_dir"]))
    lines.append(
        "Index: {} entries, {} bytes (budget {} bytes){}".format(
            idx["entry_count"], idx["bytes"], idx["budget_bytes"],
            "  [OVER BUDGET]" if idx["over_budget"] else "",
        )
    )
    lines.append("Files on disk: {}".format(idx["file_count"]))
    lines.append("")

    orphans = r["orphans"]
    lines.append("Orphaned files (on disk, no index pointer) — {}:".format(len(orphans)))
    if orphans:
        lines.append("  (report-only — deletion is opt-in; some orphans are intentional)")
        for n in orphans:
            lines.append("  - {}".format(n))
    else:
        lines.append("  none")
    lines.append("")

    dangling = r["dangling"]
    lines.append("Dangling index pointers (point to a missing file) — {}:".format(len(dangling)))
    if dangling:
        for n in dangling:
            lines.append("  - {}  (safe to drop from index)".format(n))
    else:
        lines.append("  none")
    lines.append("")

    dups = adv["duplicate_names"]
    sup = adv["superseded"]
    lines.append("Advisory — superseded / duplicate (needs your judgment):")
    if not dups and not sup:
        lines.append("  none")
    for d in dups:
        lines.append(
            "  - duplicate name '{}' shared by: {}".format(d["name"], ", ".join(d["files"]))
        )
    for s in sup:
        lines.append(
            "  - {} — '{}' marker, replacement cited: {}".format(
                s["file"], s["marker"], s["replacement"]
            )
        )
    return "\n".join(lines)


def _render_apply(r: Dict[str, object]) -> str:
    integ = r["integrity"]
    before = r["before"]
    after = r["after"]
    lines = []
    lines.append("Memory store: {}".format(r["memory_dir"]))
    lines.append("Deleted files: {}".format(", ".join(r["deleted"]) or "none"))
    if r.get("delete_failures"):
        lines.append("Could NOT delete (now unindexed orphans): {}".format(", ".join(r["delete_failures"])))
    lines.append("Index lines dropped: {}".format(len(r["index_lines_dropped"])))
    lines.append(
        "Entries: {} → {}   Index bytes: {} → {}".format(
            before["entry_count"], after["entry_count"],
            before["bytes"], after["bytes"],
        )
    )
    lines.append(
        "Integrity: {}".format("OK — no dangling pointers created" if integ["ok"] else "FAILED")
    )
    if integ["remaining_dangling"]:
        lines.append(
            "  remaining dangling pointers (rerun with --drop-index to clear): {}".format(
                ", ".join(integ["remaining_dangling"])
            )
        )
    if integ["remaining_orphans"]:
        lines.append(
            "  remaining unindexed files (kept by choice): {}".format(
                len(integ["remaining_orphans"])
            )
        )
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _split_list(value: Optional[str]) -> List[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="memory-audit.py",
        description="Audit and guarded-prune the durable memory store (issue #620).",
        add_help=True,
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="read-only detection (default)")
    mode.add_argument("--apply", action="store_true", help="perform the prune (needs --files/--drop-index)")
    p.add_argument("--dir", dest="dir", default=None, help="target memory dir (default: auto-detect)")
    p.add_argument("--json", action="store_true", help="emit JSON instead of human text")
    p.add_argument("--budget-bytes", type=int, default=DEFAULT_BUDGET_BYTES, help="index size soft budget")
    p.add_argument("--files", default=None, help="comma-separated .md basenames to delete")
    p.add_argument("--drop-index", dest="drop_index", default=None, help="comma-separated .md basenames whose dangling index lines to drop")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    _log_invocation(argv)
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.budget_bytes < 0:
        parser.error("--budget-bytes must be non-negative")

    import json  # local import keeps startup light for the common text path

    try:
        mem_dir = resolve_memory_dir(args.dir)
        if args.apply:
            result = apply_prune(
                mem_dir,
                _split_list(args.files),
                _split_list(args.drop_index),
                args.budget_bytes,
            )
            print(json.dumps(result, indent=2) if args.json else _render_apply(result))
        else:
            result = detect(mem_dir, args.budget_bytes)
            print(json.dumps(result, indent=2) if args.json else _render_check(result))
    except AuditError as exc:
        print("memory-audit.py: {}".format(exc), file=sys.stderr)
        return exc.code
    except OSError as exc:
        # Filesystem/permission/encoding failure during detection or apply — report
        # cleanly with the documented exit code instead of dumping a traceback.
        print("memory-audit.py: filesystem error: {}".format(exc), file=sys.stderr)
        return 4
    except Exception as exc:  # last-resort guard: this tool performs irreversible deletes
        print("memory-audit.py: unexpected error: {}".format(exc), file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
