#!/usr/bin/env python3
"""
Mechanical merge-conflict scan and conservative auto-resolution.

Used by the /merge-conflict skill. When in doubt, leaves hunks untouched (complex).
Does not commit — caller may git add resolved paths.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


CONFLICT_START = re.compile(r"^<<<<<<< (.+)$")
CONFLICT_MID = re.compile(r"^=======\s*$")
CONFLICT_END = re.compile(r"^>>>>>>> (.+)$")

# Lines that look like pure imports (conservative: only these patterns are "simple" one-sided adds).
_PY_IMPORT = re.compile(r"^\s*(from\s+\S+\s+import|import\s+\S+)")
_JS_TS_IMPORT = re.compile(r"^\s*import\s+[\s\S]*\s+from\s+['\"]|^\s*import\s+['\"]")


@dataclass
class ConflictHunk:
    label_ours: str
    body_ours: str
    body_theirs: str
    label_theirs: str
    start_line: int  # 1-based line of <<<<<<<
    end_line: int  # 1-based line of >>>>>>>


@dataclass
class FileResult:
    path: str
    hunks: list[tuple[ConflictHunk, str, str | None]] = field(default_factory=list)
    # (hunk, classification, resolved_body or None if complex)
    error: str | None = None
    wrote: bool = False


def _lines(s: str) -> list[str]:
    if not s:
        return []
    return s.splitlines()


def _non_blank_lines(s: str) -> list[str]:
    return [ln for ln in _lines(s) if ln.strip()]


def _rstrip_lines(s: str) -> str:
    return "\n".join(ln.rstrip() for ln in _lines(s))


def _has_nested_markers(chunk: str) -> bool:
    if "<<<<<<< " in chunk or ">>>>>>> " in chunk:
        return True
    for ln in _lines(chunk):
        if ln.startswith("=======") and ln.strip() == "=======":
            return True
    return False


def _all_import_lines(lines: Iterable[str]) -> bool:
    for ln in lines:
        t = ln.strip()
        if not t:
            continue
        if t.startswith("#"):
            return False
        if _PY_IMPORT.match(ln) or _JS_TS_IMPORT.match(ln):
            continue
        return False
    return True


def classify_and_resolve(ours: str, theirs: str) -> tuple[str, str | None, str]:
    """
    Returns (classification, resolved_or_none, reason_if_complex).

    classification is 'simple' or 'complex'.
    resolved_or_none is merged body without markers when simple.
    """
    if _has_nested_markers(ours) or _has_nested_markers(theirs):
        return "complex", None, "nested or embedded conflict markers inside hunk"

    o_nb = _non_blank_lines(ours)
    t_nb = _non_blank_lines(theirs)

    if _rstrip_lines(ours) == _rstrip_lines(theirs):
        return "simple", _rstrip_lines(ours), ""

    if o_nb == t_nb:
        # Identical non-blank line sequence; preserve blank-line structure from theirs
        return "simple", _rstrip_lines(theirs), ""

    if len(o_nb) == len(t_nb) and all(
        a.rstrip() == b.rstrip() for a, b in zip(o_nb, t_nb)
    ):
        # Per-line trailing whitespace only (non-blank lines align in order)
        return "simple", "\n".join(b.rstrip() for b in t_nb), ""

    o_empty = not o_nb
    t_empty = not t_nb

    if o_empty and not t_empty:
        if _all_import_lines(t_nb):
            # No trailing newline: resolve_file joins out_parts with "\n" between elements
            return "simple", theirs.rstrip("\n"), ""
        return "complex", None, "one side empty, other side has non-import content (possible deletion vs addition)"

    if t_empty and not o_empty:
        return "complex", None, "incoming side empty while current side has content (risky deletion)"

    if o_empty and t_empty:
        return "simple", "", ""

    return "complex", None, "both sides have differing non-blank content (semantic or formatting beyond trailing space)"


def iter_conflicts(lines: list[str]) -> Iterable[ConflictHunk]:
    i = 0
    n = len(lines)
    while i < n:
        m = CONFLICT_START.match(lines[i])
        if not m:
            i += 1
            continue
        label_ours = m.group(1).strip()
        start_line = i + 1
        i += 1
        o_buf: list[str] = []
        while i < n and not CONFLICT_MID.match(lines[i]):
            o_buf.append(lines[i])
            i += 1
        if i >= n:
            raise ValueError(f"unterminated conflict (missing =======) starting line {start_line}")
        i += 1  # skip =======
        t_buf: list[str] = []
        while i < n and not CONFLICT_END.match(lines[i]):
            t_buf.append(lines[i])
            i += 1
        if i >= n:
            raise ValueError(f"unterminated conflict (missing >>>>>>>) starting line {start_line}")
        m_end = CONFLICT_END.match(lines[i])
        label_theirs = m_end.group(1).strip() if m_end else ""
        end_line = i + 1
        i += 1
        yield ConflictHunk(
            label_ours=label_ours,
            body_ours="\n".join(o_buf),
            body_theirs="\n".join(t_buf),
            label_theirs=label_theirs,
            start_line=start_line,
            end_line=end_line,
        )


def resolve_file(path: Path, text: str) -> FileResult:
    fr = FileResult(path=str(path))
    lines = text.splitlines()
    try:
        hunks = list(iter_conflicts(lines))
    except ValueError as e:
        fr.error = str(e)
        return fr

    if not hunks:
        return fr

    out_parts: list[str] = []
    line_idx = 0
    any_simple = False
    for h in hunks:
        while line_idx < h.start_line - 1:
            out_parts.append(lines[line_idx])
            line_idx += 1
        cls, resolved, _reason = classify_and_resolve(h.body_ours, h.body_theirs)
        fr.hunks.append((h, cls, resolved))
        if cls == "simple" and resolved is not None:
            any_simple = True
            if resolved != "":
                out_parts.append(resolved)
        else:
            for j in range(h.start_line - 1, h.end_line):
                out_parts.append(lines[j])
        line_idx = h.end_line

    while line_idx < len(lines):
        out_parts.append(lines[line_idx])
        line_idx += 1

    had_complex = any(c == "complex" for _, c, _ in fr.hunks)

    if any_simple or not had_complex:
        new_text = "\n".join(out_parts)
        if text.endswith("\n") and new_text and not new_text.endswith("\n"):
            new_text += "\n"
        write_repo_text(path, new_text)
        fr.wrote = True

    return fr


def git(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        text=True,
        capture_output=True,
        check=False,
    )


def unmerged_paths(repo: Path) -> list[str]:
    p = git(["diff", "--name-only", "--diff-filter=U"], repo)
    if p.returncode != 0:
        return []
    return [ln.strip() for ln in p.stdout.splitlines() if ln.strip()]


def is_binary_bytes(b: bytes) -> bool:
    return b"\x00" in b[:8192]


def read_repo_text(path: Path) -> str:
    """Decode worktree file bytes the same way as conflict reads (non-UTF8 safe)."""
    return path.read_bytes().decode("utf-8", errors="surrogateescape")


def write_repo_text(path: Path, text: str) -> None:
    """Write text so bytes round-trip with read_repo_text (avoids UnicodeEncodeError on surrogates)."""
    path.write_bytes(text.encode("utf-8", errors="surrogateescape"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Classify and partially resolve merge conflicts.")
    ap.add_argument("--repo", type=Path, default=Path.cwd(), help="Git repository root")
    ap.add_argument("--skip-fetch", action="store_true", help="Skip git fetch origin main (for tests/offline)")
    ap.add_argument("--json", action="store_true", help="Print machine-readable JSON summary to stdout")
    args = ap.parse_args()
    repo = args.repo.resolve()

    git_dir = repo / ".git"
    if not git_dir.exists() and not git_dir.is_file():
        print("ERROR: not a git repository (.git missing)", file=sys.stderr)
        return 2

    if not args.skip_fetch:
        f = git(["fetch", "origin", "main"], repo)
        if f.returncode != 0:
            print(f"WARN: git fetch origin main failed: {f.stderr.strip()}", file=sys.stderr)

    paths = unmerged_paths(repo)
    if not paths:
        summary = {
            "unmerged_paths": [],
            "fully_resolved": [],
            "partially_resolved": [],
            "complex_report": [],
            "staged": [],
        }
        if args.json:
            print(json.dumps(summary, indent=2))
        else:
            print("No unmerged paths (git diff --name-only --diff-filter=U is empty).")
        return 0

    fully: list[str] = []
    partial: list[str] = []
    complex_report: list[dict[str, object]] = []

    for rel in paths:
        p = repo / rel
        if not p.is_file():
            complex_report.append(
                {
                    "file": rel,
                    "location": "skipped",
                    "reason": "path is not a regular file (submodule, deleted, or missing)",
                }
            )
            continue
        raw = p.read_bytes()
        if is_binary_bytes(raw):
            complex_report.append(
                {
                    "file": rel,
                    "location": "binary file",
                    "reason": "binary merge conflict requires human merge tool",
                }
            )
            continue
        text = raw.decode("utf-8", errors="surrogateescape")
        before = text
        fr = resolve_file(p, text)

        if fr.error:
            complex_report.append(
                {
                    "file": rel,
                    "location": "parse error",
                    "reason": fr.error,
                }
            )
            continue

        if not fr.hunks:
            complex_report.append(
                {
                    "file": rel,
                    "location": "entire file",
                    "reason": (
                        "unmerged path has no inline conflict markers (<<<<<<< / ======= / >>>>>>>); "
                        "resolve with git checkout --ours/--theirs, manual merge, or your merge tool, then git add"
                    ),
                }
            )
            continue

        still_has_markers = "<<<<<<< " in read_repo_text(p)

        for h, cls, _ in fr.hunks:
            if cls == "complex":
                _c, _r, reason = classify_and_resolve(h.body_ours, h.body_theirs)
                complex_report.append(
                    {
                        "file": rel,
                        "location": f"lines {h.start_line}-{h.end_line} (labels: {h.label_ours} / {h.label_theirs})",
                        "reason": reason or "classified as complex",
                    }
                )

        if not still_has_markers:
            fully.append(rel)
        elif fr.wrote and before != read_repo_text(p):
            partial.append(rel)

    staged: list[str] = []
    for rel in fully:
        g = git(["add", "--", rel], repo)
        if g.returncode != 0:
            print(f"WARN: git add failed for {rel}: {g.stderr}", file=sys.stderr)
        else:
            staged.append(rel)

    summary = {
        "unmerged_paths": paths,
        "fully_resolved": fully,
        "partially_resolved": partial,
        "complex_report": complex_report,
        "staged": staged,
    }
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print("=== merge-conflict ===")
        print(f"Unmerged: {paths}")
        if fully:
            print(f"Fully resolved + staged: {fully}")
        if partial:
            print(
                "Partially resolved (simple hunks applied in working tree; conflict markers remain): "
                + ", ".join(partial)
            )
            print("  Complete the remaining hunks manually, then git add those paths.")
        if complex_report:
            print("Complex (human judgment):")
            for item in complex_report:
                print(f"  - {item['file']}: {item['location']}")
                print(f"    why: {item['reason']}")

    exit_ok = not complex_report and len(fully) == len(paths)
    return 0 if exit_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
