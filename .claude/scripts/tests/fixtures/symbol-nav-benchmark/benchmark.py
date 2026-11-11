#!/usr/bin/env python3
"""Measure scoped ripgrep and an on-demand Python AST probe on a pinned checkout."""
import argparse
import ast
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

FIXTURE = Path(__file__).with_name("tasks.json")
SCOPE = ".claude/scripts/"
CONTRACT = "python3 benchmark.py query ROOT MODE SYMBOL (MODE: definition or callers)"
EXCLUDED_PARTS = {"fixtures", "generated", "__pycache__", "build", "dist", "node_modules"}
PRIVATE_NAMES = re.compile(r"^\.?env(?:\.|$)|credential|^auth\.|^account-config\.local", re.I)


def command(root, *args, allowed=(0,)):
    result = subprocess.run(args, cwd=root, capture_output=True, text=True, timeout=30)
    if result.returncode not in allowed:
        raise RuntimeError(f"{args[0]} exited {result.returncode}")
    return result.stdout


def source_paths(root):
    tracked = command(root, "git", "ls-files", "-z", "--", SCOPE)
    paths = []
    for name in tracked.rstrip("\0").split("\0"):
        path = Path(name)
        if path.suffix not in {".py", ".sh"} or set(path.parts) & EXCLUDED_PARTS:
            continue
        if PRIVATE_NAMES.search(path.name) or (root / path).resolve() != root / path:
            continue
        if (root / path).is_file():
            paths.append(name)
    return paths


def grep(root, pattern, paths):
    if not paths:
        return ""
    return command(root, "rg", "--no-config", "--color", "never", "--with-filename",
                   "--line-number", "--", pattern, *paths, allowed=(0, 1))


def tree_query(root, mode, symbol):
    hits = []
    for name in source_paths(root):
        if not name.endswith(".py"):
            continue
        with (root / name).open("rb") as source:
            raw = source.read()
        try:
            tree = ast.parse(raw, filename=name)
        except (SyntaxError, ValueError):
            raise RuntimeError(f"Python parse failed in {name}") from None
        for node in ast.walk(tree):
            if mode == "definition" and isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.name == symbol:
                    hits.append((name, node.lineno))
            if mode == "callers" and isinstance(node, ast.Call):
                function = node.func
                if ((isinstance(function, ast.Name) and function.id == symbol)
                        or (isinstance(function, ast.Attribute) and function.attr == symbol)):
                    hits.append((name, node.lineno))
    return "".join(f"{name}:{line}:\n" for name, line in sorted(set(hits)))


def positions(output):
    return [(name, int(line)) for name, line, _ in
            (row.split(":", 2) for row in output.splitlines())]


def confirmations(root, hits, task):
    excerpts = []
    support = {(name, line) for name, lines in task.get("support", {}).items()
               for line in lines}
    for name, line in sorted(set(hits) | support):
        lines = (root / name).read_text().splitlines()
        first = max(1, line - 1)
        excerpts.extend(f"{name}:{n}:{lines[n - 1]}\n"
                        for n in range(first, min(line + 2, len(lines)) + 1))
    return "".join(excerpts)


def expected_hits(task):
    return {(name, line) for name, lines in task["expected"].items() for line in lines}


def workflow(root, task, paths, variant):
    mode = task["id"]
    if variant == "grep":
        raw = grep(root, task["pattern"], paths)
        fallback = ""
    elif mode == "change-surface":
        raw = ""
        fallback = grep(root, task["pattern"], paths)
    else:
        raw = command(root, sys.executable, str(Path(__file__).resolve()),
                      "query", str(root), mode, task["symbol"])
        fallback = ""
        if mode == "callers":
            fallback = grep(root, task["pattern"], [path for path in paths if path.endswith(".sh")])
    hits = set(positions(raw + fallback))
    expected = expected_hits(task)
    evidence = confirmations(root, hits, task)
    visible = raw + fallback + evidence
    return {
        "raw_hits": len(set(positions(raw))),
        "raw_found": len(expected & set(positions(raw))),
        "found": len(hits & expected),
        "expected": len(expected),
        "distractors": sorted(hits - expected),
        "bytes": len(visible.encode()),
        "characters": len(visible),
        "confirmed_locations_read": len(hits),
        "hits": sorted(hits),
    }


def probe(root, mode, symbol, interpreter=sys.executable):
    return command(root, interpreter, str(Path(__file__).resolve()), "query",
                   str(root), mode, symbol)


def freshness(root, scratch):
    source = ".claude/scripts/lib/review_ledger.py"
    target = scratch / "clone"
    command(root, "git", "clone", "--quiet", "--no-local", str(root), str(target))
    original = probe(target, "definition", "cents")
    old_line = positions(original)[0][1]
    path = target / source
    path.write_text("\n\n" + path.read_text() + "\n\ndef benchmark_caller(x):\n    return cents(x)\n")
    edited = probe(target, "definition", "cents")
    assert positions(edited) == [(source, old_line + 2)] and original != edited
    assert source in grep(target, r"^def benchmark_caller\(", [source])
    assert len(positions(probe(target, "callers", "cents"))) == 11
    command(target, "git", "switch", "-q", "-c", "symbol-benchmark")
    command(target, "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "-qm", "Shift fixture lines", "--", source)
    command(target, "git", "switch", "-q", "--detach", json.loads(FIXTURE.read_text())["commit"])
    assert probe(target, "definition", "cents") == original
    other = scratch / "worktree"
    command(target, "git", "worktree", "add", "-q", str(other), "symbol-benchmark")
    assert probe(other, "definition", "cents") == edited

    path.write_text("def cents(:\n")
    try:
        probe(target, "definition", "cents")
    except RuntimeError:
        assert positions(grep(target, r"^def cents\(", [source])) == [(source, 1)]
    else:
        raise AssertionError("invalid syntax did not fail the structural probe")
    try:
        probe(other, "definition", "cents", str(scratch / "missing-python"))
    except FileNotFoundError:
        assert positions(grep(other, r"^def cents\(", [source])) == [(source, old_line + 2)]
    else:
        raise AssertionError("missing interpreter unexpectedly started")

    for name in ("lib/.credentials.py", "generated/benchmark.py"):
        relative = SCOPE + name
        excluded = other / relative
        excluded.parent.mkdir(parents=True, exist_ok=True)
        excluded.write_text("def benchmark_excluded():\n    pass\n")
        command(other, "git", "add", "--", relative)
    assert probe(other, "definition", "benchmark_excluded") == ""
    assert grep(other, r"benchmark_excluded", source_paths(other)) == ""
    assert grep(other, r'"mcp__\*"', ["global-settings.json"])
    return {"edit": True, "stale_saved_result_detected": True, "branch": True,
            "worktree": True, "malformed_python_fallback": True,
            "unavailable_python_fallback": True, "sensitive_and_generated_excluded": True,
            "json_fallback": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="worktree at the exact fixture commit")
    parser.add_argument("--scratch", type=Path, help="empty directory for disposable freshness clones")
    args = parser.parse_args()
    root = args.root.resolve()
    fixture = json.loads(FIXTURE.read_text())
    if command(root, "git", "rev-parse", "HEAD").strip() != fixture["commit"]:
        parser.error("checkout the exact commit in tasks.json")
    if command(root, "git", "status", "--porcelain", "--untracked-files=no"):
        parser.error("tracked sources must be clean")
    start = time.perf_counter()
    paths = source_paths(root)
    result = {
        "source_files": len(paths),
        "python_files": sum(path.endswith(".py") for path in paths),
        "allowlist_ms": round((time.perf_counter() - start) * 1000, 2),
        "candidate_contract_bytes": len(CONTRACT.encode()),
        "results": {},
    }
    for task in fixture["tasks"]:
        result["results"][task["id"]] = {}
        for variant in ("grep", "ast-with-fallback"):
            timings = []
            for _ in range(7):
                start = time.perf_counter()
                row = workflow(root, task, paths, variant)
                timings.append((time.perf_counter() - start) * 1000)
            assert row["found"] == row["expected"], (task["id"], variant, row)
            row.pop("hits")
            row["first_ms"] = round(timings[0], 2)
            row["median_ms"] = round(statistics.median(timings), 2)
            row["max_ms"] = round(max(timings), 2)
            result["results"][task["id"]][variant] = row
    if args.scratch:
        scratch = args.scratch.resolve()
        if not scratch.is_dir() or any(scratch.iterdir()):
            parser.error("--scratch must be an existing empty directory")
        result["freshness"] = freshness(root, scratch)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "query":
        _, _, directory, query_mode, symbol_name = sys.argv
        try:
            print(tree_query(Path(directory), query_mode, symbol_name), end="")
        except RuntimeError as error:
            sys.exit(str(error))
    else:
        main()
