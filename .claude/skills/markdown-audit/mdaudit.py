#!/usr/bin/env python3
"""mdaudit.py — deterministic engine behind the /markdown-audit skill.

The skill audits Markdown bottom-up at seven levels (sentence, block, section,
page, document, group, repo). Judgment about whether writing earns its place is
done by read-only agents; everything mechanical is done here, so two runs over
the same snapshot see the same units, the same candidate pairs and the same
word arithmetic.

READ-ONLY CONTRACT: no subcommand writes anywhere. Every result goes to stdout;
the caller decides where to store it (outside the checkout).

Subcommands:
  levels       --kind file|folder|repo [--from L] [--stop-at L]
               Print "FROM STOP" as two integers. Levels are 1-7 or a name
               (sentence block section page document group repo). Defaults: a
               file or folder runs 1-7; a repo-wide run runs 5-7. Exit 2 on an
               unknown level, FROM > STOP, or a repo run stopped below 5
               without --from.
  inventory    [--target PATH]
               Snapshot JSON: HEAD, checkout, target kind, in-scope files, the
               full Markdown corpus, sibling groups, per-file line/word counts
               and exclusions. Corpus = `git ls-files --cached --others
               --exclude-standard -z -- '*.md'`; a symlink is followed only
               when its target is inside the checkout; files are deduplicated
               by resolved path.
  segment      --snapshot SNAP.json [FILE ...]
               Unit map per file (default: every in-scope file): blocks,
               sections, pages, document, each with 1-based start/end lines and
               a `wc -w` style word count. Fence aware (matched character and
               minimum length). ATX headings only; Setext headings are not
               recognised. No sentence units: a sentence is located by the
               first physical line it starts on.
  pairs        --snapshot SNAP.json --level 6|7 [--limit N]
               Ranked candidate file pairs for overlap/contradiction review:
               shared 8-word shingles (outside fences) and shared identifiers
               (script paths, --flags, /slash-names, heading terms), with the
               matching line ranges in both files. A candidate is evidence for
               review, never a finding. Level 6 compares files inside one
               sibling group; level 7 compares in-scope files with the whole
               corpus. Default limit 40.
  fingerprint  --snapshot SNAP.json
               JSON of HEAD, a hash of `git status --porcelain=v1 -z` and a
               content hash of every corpus file. Taken before and after a run.
  verify-unchanged --snapshot SNAP.json --before BEFORE.json
               Re-take the fingerprint and compare. Exit 0 unchanged, 1 changed
               (differences printed), 2 usage error.
  report       --snapshot SNAP.json --findings F.jsonl [--coverage C.jsonl]
               [--pairs PAIRS.json ...] [--from L] [--stop-at L] [--format md|json]
               Validate findings, compute word-removal arithmetic, render the
               seven-level report. Invalid findings are listed, never repaired.
               Every candidate pair in a --pairs file with no "reviewed"
               coverage line is reported as unreviewed (unknown, not clean).

Exit codes: 0 ok, 1 changed (verify-unchanged only), 2 usage/input error.
"""

import argparse
import errno
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from collections import defaultdict

LEVEL_NAMES = ["sentence", "block", "section", "page", "document", "group", "repo"]
ACTIONS = ("cut", "merge", "move", "keep")
PAGE_LINES = 50
SHINGLE = 8
PAIR_LIMIT = 40
COMMON_CAP = 15  # a shingle/identifier in more files than this is boilerplate
REASON_MAX = 240

FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
BLANK_QUOTE_RE = re.compile(r"^ {0,3}(?:>[ \t]*)+$")
HEADING_RE =re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t#]*$")
LIST_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
WORD_RE = re.compile(r"[A-Za-z0-9_']+")
ID_RES = [
    re.compile(r"[\w./-]+\.(?:sh|py)\b"),
    re.compile(r"(?<![\w-])--[a-z][a-z0-9-]+"),
    re.compile(r"(?<![\w./`-])/[a-z][a-z0-9-]{2,}\b(?!/)"),
]


def die(msg, code=2):
    sys.stderr.write("mdaudit: " + msg + "\n")
    sys.exit(code)


def emit(obj):
    json.dump(obj, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")


def parse_level(value):
    if value is None or value == "":
        return None
    v = str(value).strip().lower()
    if v.isdigit() and 1 <= int(v) <= 7:
        return int(v)
    if v in LEVEL_NAMES:
        return LEVEL_NAMES.index(v) + 1
    die("unknown level %r (use 1-7 or one of: %s)" % (value, ", ".join(LEVEL_NAMES)))


def level_range(kind, frm, stop):
    lo = parse_level(frm)
    hi = parse_level(stop)
    default_lo = 5 if kind == "repo" else 1
    if hi is None:
        hi = 7
    if lo is None:
        if hi < default_lo:
            die("a repo-wide run starts at level 5; pass --from to run levels below 5 repo-wide")
        lo = default_lo
    if lo > hi:
        die("--from (%d) is above --stop-at (%d)" % (lo, hi))
    return lo, hi


# ---------------------------------------------------------------- git / files

def git(top, *args):
    try:
        return subprocess.run(["git", "-C", top] + list(args), check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        die("git %s failed: %s" % (" ".join(args), getattr(exc, "stderr", b"") or exc))


def checkout_top(cwd):
    try:
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError):
        die("not inside a git checkout: %s" % cwd)
    return os.path.realpath(out.decode().strip())


def read_bytes(top, rel):
    """Read a corpus file, refusing any path that now resolves outside the
    checkout (a file swapped for an external symlink after inventory)."""
    if is_env_file(rel):
        die("%s is an environment file; it is never read" % rel)
    try:
        st, data = open_in_checkout(top, rel, read=True)
    except EscapeError:
        die("%s now resolves outside the checkout; restart the audit" % rel)
    except OSError as exc:
        die("cannot read %s: %s" % (rel, exc))
    if data is None:
        die("%s is no longer a regular file; restart the audit" % rel)
    return data


class EscapeError(Exception):
    """A path component is a symlink or not a directory: the walk would leave
    the checkout (or a parent was swapped mid-run)."""


def open_in_checkout(top, rel, read=False):
    """Walk rel from a descriptor on the checkout root, one component at a
    time, never following a symlink in any component. Returns (lstat result
    of the leaf, bytes or None). Bytes are read only when read=True and the
    leaf is a regular, non-environment file, opened non-blocking with
    O_NOFOLLOW on the descriptor the check used, so no swap between check and
    open can redirect it. Raises EscapeError for a symlinked or non-directory
    parent, OSError (FileNotFoundError) when the path is missing."""
    parts = [x for x in rel.split("/") if x not in ("", ".")]
    if not parts or ".." in parts:
        raise EscapeError(rel)
    dflags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(top, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        for part in parts[:-1]:
            try:
                nfd = os.open(part, dflags, dir_fd=fd)
            except OSError as exc:
                if exc.errno in (errno.ELOOP, errno.ENOTDIR):
                    raise EscapeError(rel)
                raise
            os.close(fd)
            fd = nfd
        leaf = parts[-1]
        st = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        if not read or not stat.S_ISREG(st.st_mode) or is_env_file(leaf):
            return st, None
        try:
            lfd = os.open(leaf, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0),
                          dir_fd=fd)
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                return st, None
            raise
        try:
            if not stat.S_ISREG(os.fstat(lfd).st_mode):
                return st, None
            return st, read_fd(lfd)
        finally:
            os.close(lfd)
    finally:
        os.close(fd)


def read_fd(fd):
    chunks = []
    while True:
        b = os.read(fd, 1 << 20)
        if not b:
            break
        chunks.append(b)
    return b"".join(chunks)


def read_regular(path):
    """Read a regular file without blocking: open non-blocking and refuse
    anything fstat() does not report as a regular file (FIFO, device,
    socket). Returns None for a non-regular file; OSError propagates."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        return read_fd(fd)
    finally:
        os.close(fd)


def is_env_file(path):
    base = os.path.basename(path)
    return base == ".env" or base.startswith(".env.")


def read_lines(top, rel, data=None):
    if data is None:
        data = read_bytes(top, rel)
    text = data.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
    if not text:
        return []
    lines = text.split("\n")
    return lines[:-1] if text.endswith("\n") else lines


def words(lines):
    return sum(len(line.split()) for line in lines)


def inside(top, real):
    return real == top or real.startswith(top + os.sep)


def load_snapshot(path):
    try:
        with open(path) as fh:
            snap = json.load(fh)
    except (OSError, ValueError) as exc:
        die("cannot read snapshot %s: %s" % (path, exc))
    for key in ("checkout", "corpus", "in_scope", "files"):
        if key not in snap:
            die("snapshot %s lacks %r" % (path, key))
    return snap


def group_key(rel):
    parts = rel.split("/")
    if len(parts) >= 4 and parts[0] == ".claude" and parts[1] == "skills":
        return ".claude/skills"
    return os.path.dirname(rel) or "."


def cmd_inventory(args):
    cwd = os.getcwd()
    top = checkout_top(cwd)
    raw = git(top, "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md")
    corpus, seen, excluded = [], set(), []
    for item in sorted(set(p for p in raw.decode("utf-8", "replace").split("\0") if p)):
        full = os.path.join(top, item)
        if not os.path.lexists(full):
            excluded.append({"path": item, "reason": "listed by git but missing on disk"})
            continue
        real = os.path.realpath(full)
        if not inside(top, real):
            excluded.append({"path": item, "reason": "symlink resolves outside the checkout"})
            continue
        if is_env_file(full) or is_env_file(real):
            excluded.append({"path": item, "reason": "environment file (never read)"})
            continue
        if not os.path.isfile(real):
            excluded.append({"path": item, "reason": "not a regular file"})
            continue
        rel = os.path.relpath(real, top)
        if rel in seen:
            if rel != item:
                excluded.append({"path": item, "reason": "duplicate of " + rel})
            continue
        seen.add(rel)
        corpus.append(rel)
    corpus.sort()

    target = args.target
    if not target:
        kind, scope = "repo", list(corpus)
    else:
        real = os.path.realpath(os.path.join(cwd, target))
        if not os.path.exists(real):
            die("target does not exist: %s" % target)
        if not inside(top, real):
            die("target resolves outside the checkout: %s" % target)
        rel = os.path.relpath(real, top)
        if real == top:
            kind, scope = "repo", list(corpus)
        elif os.path.isdir(real):
            kind = "folder"
            scope = [f for f in corpus if f.startswith(rel + "/")]
            if not scope:
                die("no Markdown files under %s" % target)
        else:
            kind = "file"
            if not rel.endswith(".md"):
                die("target is not a Markdown file: %s" % target)
            if rel not in seen:
                die("target is not in the Markdown corpus (ignored or excluded): %s" % target)
            scope = [rel]

    files = {}
    for rel in corpus:
        data = read_bytes(top, rel)
        lines = read_lines(top, rel, data)
        files[rel] = {"lines": len(lines), "words": words(lines),
                      "sha256": hashlib.sha256(data).hexdigest()}
    groups = defaultdict(list)
    for rel in corpus:
        groups[group_key(rel)].append(rel)
    wanted = set(group_key(r) for r in scope)
    emit({
        "checkout": top,
        "head": git(top, "rev-parse", "HEAD").decode().strip(),
        "target": target or "",
        "target_kind": kind,
        "in_scope": scope,
        "corpus": corpus,
        "files": files,
        "groups": {k: v for k, v in sorted(groups.items()) if k in wanted},
        "excluded": excluded,
    })


# ---------------------------------------------------------------- segmentation

def scan(lines):
    """Classify every line: 'blank', 'text', 'heading', 'fence', 'comment',
    'frontmatter'. Return (kinds, fence_spans, heading list, unclosed flag)."""
    n = len(lines)
    kinds = ["text"] * n
    fences, headings, skipped = [], [], []
    unclosed = False
    i = 0
    if n and lines[0].strip() == "---":
        for j in range(1, n):
            if lines[j].strip() in ("---", "..."):
                for k in range(0, j + 1):
                    kinds[k] = "frontmatter"
                skipped.append({"kind": "frontmatter", "start": 1, "end": j + 1})
                i = j + 1
                break
    while i < n:
        line = lines[i]
        m = FENCE_RE.match(line)
        # CommonMark: a backtick fence's info string may not contain a backtick,
        # so ```foo``` opening a paragraph is inline code, not a fence.
        if m and m.group(1)[0] == "`" and "`" in m.group(2):
            m = None
        if m:
            mark = m.group(1)
            ch, size = mark[0], len(mark)
            j = i + 1
            close = None
            while j < n:
                c = re.match(r"^ {0,3}(" + re.escape(ch) + "{" + str(size) + r",})\s*$", lines[j])
                if c:
                    close = j
                    break
                j += 1
            end = close if close is not None else n - 1
            if close is None:
                unclosed = True
            for k in range(i, end + 1):
                kinds[k] = "fence"
            fences.append((i, end))
            i = end + 1
            continue
        if line.lstrip().startswith("<!--"):
            j = i
            while j < n and "-->" not in lines[j]:
                j += 1
            end = min(j, n - 1)
            for k in range(i, end + 1):
                kinds[k] = "comment"
            skipped.append({"kind": "comment", "start": i + 1, "end": end + 1})
            i = end + 1
            continue
        if not line.strip() or BLANK_QUOTE_RE.match(line):
            # A quote line holding only ">" separates quoted paragraphs.
            kinds[i] = "blank"
        else:
            h = HEADING_RE.match(line)
            if h:
                kinds[i] = "heading"
                headings.append((i, len(h.group(1)), (h.group(2) or "").strip()))
        i += 1
    return kinds, fences, headings, skipped, unclosed


def unit(lines, start, end, **extra):
    d = {"start": start + 1, "end": end + 1, "words": words(lines[start:end + 1])}
    d.update(extra)
    return d


def segment_lines(lines):
    n = len(lines)
    kinds, fences, headings, skipped, unclosed = scan(lines)
    fence_at = {s: e for s, e in fences}
    blocks = []
    i = 0
    while i < n:
        k = kinds[i]
        if k in ("blank", "frontmatter", "comment"):
            i += 1
            continue
        if k == "fence":
            e = fence_at.get(i, i)
            blocks.append(unit(lines, i, e, kind="fence"))
            i = e + 1
            continue
        if k == "heading":
            blocks.append(unit(lines, i, i, kind="heading"))
            i += 1
            continue
        j = i
        while j + 1 < n and kinds[j + 1] == "text":
            j += 1
        first = lines[i].lstrip()
        kind = "list" if LIST_RE.match(lines[i]) else ("table" if first.startswith("|") else "paragraph")
        blocks.append(unit(lines, i, j, kind=kind))
        i = j + 1

    def last_content(lo, hi):
        while hi > lo and kinds[hi] in ("blank",):
            hi -= 1
        return hi

    sections = []
    for idx, (ln, lvl, title) in enumerate(headings):
        end = n - 1
        for ln2, lvl2, _ in headings[idx + 1:]:
            if lvl2 <= lvl:
                end = ln2 - 1
                break
        sections.append(unit(lines, ln, last_content(ln, end), level=lvl, title=title))

    # Page boundaries: headings at the shallowest level used at least twice
    # (a lone H1 title does not make the whole file one page); otherwise the
    # shallowest level present.
    levels_used = defaultdict(int)
    for _, lvl, _ in headings:
        levels_used[lvl] += 1
    repeated = [l for l, c in levels_used.items() if c >= 2]
    page_level = min(repeated) if repeated else (min(levels_used) if levels_used else None)
    cuts = sorted(set(ln for ln, lvl, _ in headings if lvl == page_level)) if page_level else []
    regions, prev = [], 0
    for c in cuts:
        if c > prev:
            regions.append((prev, c - 1))
        prev = c
    regions.append((prev, n - 1))
    pages = []
    for lo, hi in regions:
        cur = []
        for b in blocks:
            s, e = b["start"] - 1, b["end"] - 1
            if s < lo or s > hi:
                continue
            if cur and (e - (cur[0]["start"] - 1) + 1) > PAGE_LINES:
                pages.append(unit(lines, cur[0]["start"] - 1, cur[-1]["end"] - 1))
                cur = []
            cur.append(b)
        if cur:
            pages.append(unit(lines, cur[0]["start"] - 1, cur[-1]["end"] - 1))

    return {
        "lines": n,
        "words": words(lines),
        "unclosed_fence": unclosed,
        "skipped": skipped,
        "blocks": blocks,
        "sections": sections,
        "pages": pages,
        "document": {"start": 1 if n else 0, "end": n, "words": words(lines)},
    }


def cmd_segment(args):
    snap = load_snapshot(args.snapshot)
    top = snap["checkout"]
    targets = args.files or snap["in_scope"]
    out = {}
    for rel in targets:
        if rel not in snap["files"]:
            die("not in the snapshot corpus: %s" % rel)
        out[rel] = segment_lines(read_lines(top, rel))
    emit({"head": snap.get("head", ""), "page_lines": PAGE_LINES, "files": out})


# ---------------------------------------------------------------- pairs

def features(lines):
    kinds = scan(lines)[0]
    toks = []
    ids = defaultdict(set)
    for i, line in enumerate(lines):
        if kinds[i] in ("fence", "frontmatter", "comment"):
            continue
        for w in WORD_RE.findall(line):
            toks.append((w.lower(), i + 1))
        for rx in ID_RES:
            for m in rx.findall(line):
                ids[m.strip("./")].add(i + 1)
        if kinds[i] == "heading":
            h = HEADING_RE.match(line)
            term = " ".join(WORD_RE.findall((h.group(2) or "").lower()))
            if len(term.split()) >= 2:
                ids["heading:" + term].add(i + 1)
    shingles = defaultdict(set)
    for k in range(len(toks) - SHINGLE + 1):
        key = " ".join(t for t, _ in toks[k:k + SHINGLE])
        shingles[key].add((toks[k][1], toks[k + SHINGLE - 1][1]))
    return shingles, ids


def merge_ranges(spans, gap=0):
    out = []
    for s, e in sorted(spans):
        if out and s <= out[-1][1] + 1 + gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def cmd_pairs(args):
    snap = load_snapshot(args.snapshot)
    top = snap["checkout"]
    level = int(args.level)
    scope = set(snap["in_scope"])
    if level == 6:
        universe = sorted(set(f for g in snap.get("groups", {}).values() for f in g))
        group_of = {}
        for g, members in snap.get("groups", {}).items():
            for f in members:
                group_of[f] = g
    else:
        universe = list(snap["corpus"])
        group_of = None
    feats = {}
    for rel in universe:
        feats[rel] = features(read_lines(top, rel))

    def eligible(a, b):
        if a == b or (a not in scope and b not in scope):
            return False
        return group_of is None or group_of.get(a) == group_of.get(b)

    sh_index, id_index = defaultdict(list), defaultdict(list)
    for rel, (sh, ids) in feats.items():
        for key in sh:
            sh_index[key].append(rel)
        for key in ids:
            id_index[key].append(rel)
    shared_sh, shared_id = defaultdict(set), defaultdict(set)
    for key, members in sh_index.items():
        if 2 <= len(members) <= COMMON_CAP:
            for x in range(len(members)):
                for y in range(x + 1, len(members)):
                    a, b = sorted((members[x], members[y]))
                    if eligible(a, b):
                        shared_sh[(a, b)].add(key)
    for key, members in id_index.items():
        if 2 <= len(members) <= COMMON_CAP:
            for x in range(len(members)):
                for y in range(x + 1, len(members)):
                    a, b = sorted((members[x], members[y]))
                    if eligible(a, b):
                        shared_id[(a, b)].add(key)
    candidates = []
    for pair in set(shared_sh) | set(shared_id):
        nsh, nid = len(shared_sh.get(pair, ())), len(shared_id.get(pair, ()))
        if nsh < args.min_shingles and nid < args.min_identifiers:
            continue
        a, b = pair
        ranges = {}
        for rel in pair:
            spans = []
            for key in shared_sh.get(pair, ()):
                spans.extend(feats[rel][0][key])
            for key in shared_id.get(pair, ()):
                spans.extend((ln, ln) for ln in feats[rel][1][key])
            ranges[rel] = [{"start": s, "end": e} for s, e in merge_ranges(spans, gap=2)[:12]]
        candidates.append({
            "a": a, "b": b, "score": nsh + 0.25 * nid,
            "shared_shingles": nsh, "shared_identifiers": nid,
            "identifiers": sorted(shared_id.get(pair, ()))[:12],
            "ranges_a": ranges[a], "ranges_b": ranges[b],
        })
    candidates.sort(key=lambda c: (-c["score"], c["a"], c["b"]))
    kept = candidates[:args.limit]
    emit({
        "head": snap.get("head", ""), "level": level, "shingle_words": SHINGLE,
        "limit": args.limit, "total_candidates": len(candidates),
        "dropped_by_limit": len(candidates) - len(kept), "pairs": kept,
        "note": "a candidate is evidence for review, not a finding",
    })


# ---------------------------------------------------------------- read-only check

def path_digest(full, top=None):
    """Digest one path without following anything out of the checkout. With
    top, the path is walked from a checkout descriptor (no symlinked parent is
    ever followed); a leaf symlink is hashed by its target string; special
    files (FIFO, socket, device) and environment files by metadata only, never
    opened. None for a directory."""
    if top is None:
        top, rel = os.path.dirname(full) or ".", os.path.basename(full)
    else:
        rel = os.path.relpath(full, top)
    try:
        st, data = open_in_checkout(top, rel, read=True)
    except EscapeError:
        return "outside:parent-is-not-a-real-directory"
    except OSError:
        return "missing"
    if stat.S_ISDIR(st.st_mode):
        return None
    if stat.S_ISLNK(st.st_mode):
        try:
            return "link:" + hashlib.sha256(os.fsencode(os.readlink(full))).hexdigest()
        except OSError:
            return "link:unreadable"
    meta = "meta:%o:%d:%d" % (st.st_mode, st.st_size, st.st_mtime_ns)
    return meta if data is None else hashlib.sha256(data).hexdigest()


def fingerprint(snap):
    top = snap["checkout"]
    # --no-optional-locks: never refresh (write) the index while auditing.
    st = git(top, "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all")
    # Hash every corpus file plus every path git reports as dirty, so a second
    # edit to an already-dirty file (Markdown or not) is still caught.
    paths = set(snap["corpus"])
    entries = st.decode("utf-8", "replace").split("\0")
    i = 0
    while i < len(entries):
        e = entries[i]
        if len(e) > 3:
            paths.add(e[3:])
            if e[0] in "RC":
                i += 1  # rename/copy: the next entry is the source path
        i += 1
    hashes = {}
    for rel in sorted(paths):
        hashes[rel] = path_digest(os.path.join(top, rel), top)
    hashes = {k: v for k, v in hashes.items() if v is not None}
    return {"head": git(top, "rev-parse", "HEAD").decode().strip(),
            "status_sha256": hashlib.sha256(st).hexdigest(), "files": hashes}


def cmd_fingerprint(args):
    emit(fingerprint(load_snapshot(args.snapshot)))


def cmd_verify(args):
    snap = load_snapshot(args.snapshot)
    try:
        with open(args.before) as fh:
            before = json.load(fh)
    except (OSError, ValueError) as exc:
        die("cannot read %s: %s" % (args.before, exc))
    now = fingerprint(snap)
    diffs = []
    if snap.get("head") and snap.get("head") != before.get("head"):
        diffs.append("HEAD moved between inventory and baseline: %s -> %s" % (snap.get("head"), before.get("head")))
    if before.get("head") != now["head"]:
        diffs.append("HEAD moved: %s -> %s" % (before.get("head"), now["head"]))
    if before.get("status_sha256") != now["status_sha256"]:
        diffs.append("git status changed")
    for rel in sorted(set(before.get("files", {})) | set(now["files"])):
        if before.get("files", {}).get(rel) != now["files"].get(rel):
            diffs.append("content changed: " + rel)
    # The snapshot's own hashes bind the line counts findings were checked
    # against to the content the baseline saw.
    for rel, meta in sorted(snap["files"].items()):
        if meta.get("sha256") and meta["sha256"] != now["files"].get(rel) \
                and "content changed: " + rel not in diffs:
            diffs.append("content changed since inventory: " + rel)
    if diffs:
        print("CHANGED")
        for d in diffs:
            print("  " + d)
        sys.exit(1)
    print("UNCHANGED")


# ---------------------------------------------------------------- report

class ParseError(str):
    """A JSONL line that did not decode to an object; kept apart from agent fields."""


def _no_constant(name):
    raise ValueError("non-finite number: " + name)


def _finite_float(text):
    v = float(text)
    if v != v or v in (float("inf"), float("-inf")):
        raise ValueError("non-finite number: " + text)
    return v


def read_jsonl(path):
    rows = []
    if not path:
        return rows
    try:
        with open(path) as fh:
            for n, line in enumerate(fh, 1):
                if line.strip():
                    try:
                        row = json.loads(line, parse_constant=_no_constant, parse_float=_finite_float)
                    except ValueError:
                        row = None
                    if not isinstance(row, dict):
                        row = ParseError("line %d is not a JSON object with finite numbers" % n)
                    rows.append(row)
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc))
    return rows


def line_no(v):
    """A whole line number: an int (not bool) or a digit string; 3.9 is rejected."""
    if isinstance(v, bool):
        raise ValueError(v)
    if isinstance(v, int):
        return v
    if isinstance(v, str) and v.strip().isdigit():
        return int(v)
    raise ValueError(v)


def validate(f, snap):
    errs = []
    if isinstance(f, ParseError):
        return [str(f)]
    try:
        lvl = line_no(f.get("level"))
    except (TypeError, ValueError):
        lvl = parse_level_soft(f.get("level"))
    if lvl is None or not 1 <= lvl <= 7:
        errs.append("level must be 1-7")
    act = f.get("action")
    if act not in ACTIONS:
        errs.append("action must be one of " + "/".join(ACTIONS))
    reason = f.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        errs.append("reason is required")
    elif re.search("[\r\n\v\f\x85\u2028\u2029]", reason) or len(reason) > REASON_MAX:
        errs.append("reason must be one line of at most %d characters" % REASON_MAX)
    if act in ("merge", "move") and not str(f.get("target") or "").strip():
        errs.append("%s needs a target" % act)

    for key in ("file", "other_file", "target"):
        if key in f and f[key] is not None and not isinstance(f[key], str):
            errs.append("%s must be a string" % key)
    if errs and any(e.endswith("must be a string") for e in errs):
        return errs

    def check_loc(file_key, s_key, e_key, pool):
        rel = f.get(file_key)
        if rel not in pool:
            errs.append("%s %r is not in the snapshot" % (file_key, rel))
            return
        total = snap["files"][rel]["lines"]
        try:
            s, e = line_no(f.get(s_key)), line_no(f.get(e_key, f.get(s_key)))
        except (TypeError, ValueError):
            errs.append("%s/%s must be line numbers" % (s_key, e_key))
            return
        if not 1 <= s <= e <= total:
            errs.append("%s lines %s-%s outside 1-%d" % (rel, s, e, total))

    pool = snap["corpus"] if (lvl or 0) >= 6 else snap["in_scope"]
    check_loc("file", "start", "end", pool)
    if (lvl or 0) >= 6:
        if not f.get("other_file"):
            errs.append("levels 6-7 need other_file with other_start/other_end")
        else:
            check_loc("other_file", "other_start", "other_end", snap["corpus"])
            a, b = f.get("file"), f.get("other_file")
            if a == b:
                errs.append("a pair needs two different files")
            if a not in snap["in_scope"] and b not in snap["in_scope"]:
                errs.append("neither file of the pair is in scope")
            if lvl == 6:
                groups = [set(m) for m in snap.get("groups", {}).values()]
                if not any(a in g and b in g for g in groups):
                    errs.append("level 6 pairs must share a sibling group")
    elif any(k in f for k in ("other_file", "other_start", "other_end")):
        errs.append("other_file/other_start/other_end belong to levels 6-7 only")
    return errs


def parse_level_soft(v):
    v = str(v or "").strip().lower()
    return LEVEL_NAMES.index(v) + 1 if v in LEVEL_NAMES else None


def norm_level(v):
    try:
        return line_no(v)
    except (TypeError, ValueError):
        return parse_level_soft(v)


def count_ranges(top, rel, spans, cache):
    if rel not in cache:
        cache[rel] = read_lines(top, rel)
    lines = cache[rel]
    return sum(words(lines[s - 1:e]) for s, e in merge_ranges(spans))


def span_lines(spans):
    for s, e in spans:
        for n in range(s, e + 1):
            yield n


def count_lines(top, rel, line_numbers, cache):
    if rel not in cache:
        cache[rel] = read_lines(top, rel)
    return sum(len(cache[rel][n - 1].split()) for n in line_numbers)


def cmd_report(args):
    snap = load_snapshot(args.snapshot)
    top = snap["checkout"]
    lo, hi = level_range(snap.get("target_kind", "file"), args.from_level, args.stop_at)
    valid, invalid = [], []
    for f in read_jsonl(args.findings):
        errs = validate(f, snap)
        lvl = None if errs else norm_level(f.get("level"))
        if not errs and not lo <= lvl <= hi:
            errs.append("level %d is outside the run range %d-%d" % (lvl, lo, hi))
        if errs:
            invalid.append({"finding": None if isinstance(f, ParseError) else f, "errors": errs})
        else:
            f = dict(f)
            f["level"] = lvl
            f["end"] = int(f.get("end", f["start"]))
            f["start"] = int(f["start"])
            valid.append(f)

    # A level-6/7 finding counts only when its pair is a candidate pair the
    # report lists as reviewed (in a --pairs file and with a "reviewed"
    # coverage line); otherwise it is listed apart and kept out of tallies and
    # filing.
    cov = coverage(read_jsonl(args.coverage), snap, lo, hi, args.pairs)
    reviewed_pairs = set((x["level"], tuple(x["pair"])) for x in cov["pairs"]["reviewed"])
    pair_unreviewed, checked = [], []
    for f in valid:
        if f["level"] >= 6 and (f["level"], tuple(sorted((f["file"], f["other_file"])))) not in reviewed_pairs:
            pair_unreviewed.append(f)
        else:
            checked.append(f)
    valid = checked

    # A cut/merge/move overlapping a `keep` range in the same file is a
    # conflict: it is listed, excluded from the tallies and from filing.
    keeps = defaultdict(list)
    for f in valid:
        if f["action"] == "keep":
            keeps[f["file"]].append((f["start"], f["end"]))
            if f.get("other_file"):
                keeps[f["other_file"]].append((int(f["other_start"]), int(f.get("other_end", f["other_start"]))))
    conflicts, kept_valid = [], []
    def hits_keep(rel, lo_, hi_):
        return any(s <= hi_ and lo_ <= e for s, e in keeps[rel])

    for f in valid:
        clash = f["action"] != "keep" and (
            hits_keep(f["file"], f["start"], f["end"])
            or (f.get("other_file") and hits_keep(
                f["other_file"], int(f["other_start"]), int(f.get("other_end", f["other_start"])))))
        if clash:
            conflicts.append(f)
        else:
            kept_valid.append(f)
    valid = kept_valid

    cache = {}
    per_level = {}
    total_rm, total_mv = defaultdict(list), defaultdict(list)
    for lvl in range(lo, hi + 1):
        rows = [f for f in valid if f["level"] == lvl]
        spans = {a: defaultdict(list) for a in ACTIONS}
        for f in rows:
            spans[f["action"]][f["file"]].append((f["start"], f["end"]))
        removed = defaultdict(list)
        for a in ("cut", "merge"):
            for rel, sp in spans[a].items():
                removed[rel].extend(sp)
                total_rm[rel].extend(sp)
        for rel, sp in spans["move"].items():
            total_mv[rel].extend(sp)
        per_level[lvl] = {
            "findings": len(rows),
            "cut": sum(count_ranges(top, r, s, cache) for r, s in spans["cut"].items()),
            "merge": sum(count_ranges(top, r, s, cache) for r, s in spans["merge"].items()),
            "removed": sum(count_ranges(top, r, s, cache) for r, s in removed.items()),
            "moved": sum(count_ranges(top, r, s, cache) for r, s in spans["move"].items()),
            "keep": 0,
        }
    result = {
        "head": snap.get("head", ""), "target": snap.get("target", ""),
        "target_kind": snap.get("target_kind"), "from": lo, "stop_at": hi,
        "findings": valid, "invalid": invalid, "per_level": per_level,
        "total_removed": sum(count_ranges(top, r, s, cache) for r, s in total_rm.items()),
        "total_moved": sum(count_lines(top, r, set(span_lines(s)) - set(span_lines(total_rm.get(r, []))), cache)
                           for r, s in total_mv.items()),
        "conflicts": conflicts,
        "unreviewed_pair_findings": pair_unreviewed,
        "note": "per-level figures can add up to more than the total: a line cut at two levels is counted once "
                "in the total, and a moved line that is also removed counts only as removed. Counts are words on the "
                "affected lines: a sentence cut on a line holding other sentences counts the whole line, so "
                "sentence-level figures are an upper bound",
        "coverage": cov,
        "excluded": snap.get("excluded", []),
    }
    if args.format == "json":
        emit(result)
    else:
        sys.stdout.write(render(result))


def coverage(rows, snap, lo, hi, pair_files):
    reviewed = set()
    reviewed_pairs = set()
    for r in rows:
        if not isinstance(r, dict):
            continue
        lvl = norm_level(r.get("level"))
        if lvl is None:
            continue
        pr = r.get("pair")
        if pr is not None:
            ok = isinstance(pr, list) and len(pr) == 2 and all(isinstance(x, str) for x in pr)
            if ok and r.get("status") == "reviewed":
                reviewed_pairs.add((lvl, tuple(sorted(pr))))
            continue
        if r.get("status") == "reviewed" and isinstance(r.get("file"), str):
            reviewed.add((r["file"], lvl))
    pairs = {"reviewed": [], "unreviewed": [], "omitted_by_limit": {}}
    for path in pair_files or []:
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError) as exc:
            die("cannot read pairs file %s: %s" % (path, exc))
        lvl = int(data.get("level", 0))
        if not lo <= lvl <= hi:
            continue
        pairs["omitted_by_limit"][str(lvl)] = int(data.get("dropped_by_limit", 0))
        for p in data.get("pairs", []):
            key = (lvl, tuple(sorted((p["a"], p["b"]))))
            bucket = "reviewed" if key in reviewed_pairs else "unreviewed"
            pairs[bucket].append({"level": lvl, "pair": list(key[1])})
    unreviewed = []
    for rel in snap["in_scope"]:
        for lvl in range(lo, min(hi, 5) + 1):
            if (rel, lvl) not in reviewed:
                unreviewed.append({"file": rel, "level": lvl})
    expected = len(snap["in_scope"]) * max(0, min(hi, 5) - lo + 1)
    return {"file_levels_expected": expected, "file_levels_reviewed": expected - len(unreviewed),
            "file_levels_unreviewed": unreviewed, "pairs": pairs}


def loc(f):
    s, e = f["start"], f["end"]
    here = "%s:%d" % (f["file"], s) if s == e else "%s:%d-%d" % (f["file"], s, e)
    if f.get("other_file"):
        os_, oe = int(f.get("other_start")), int(f.get("other_end", f.get("other_start")))
        other = "%s:%d" % (f["other_file"], os_) if os_ == oe else "%s:%d-%d" % (f["other_file"], os_, oe)
        return here + " <-> " + other
    return here


def cell(text):
    return str(text or "").replace("|", "\\|").replace("\n", " ")


def render(r):
    out = ["# Markdown audit — %s" % (r["target"] or "whole repo"), "",
           "HEAD `%s` · target kind %s · levels %d-%d" % (r["head"][:12], r["target_kind"], r["from"], r["stop_at"]), ""]
    for lvl in range(r["from"], r["stop_at"] + 1):
        rows = [f for f in r["findings"] if f["level"] == lvl and f["action"] != "keep"]
        kept = len([f for f in r["findings"] if f["level"] == lvl and f["action"] == "keep"])
        out.append("## Level %d — %s (%d)" % (lvl, LEVEL_NAMES[lvl - 1], len(rows)))
        out.append("")
        if rows:
            out += ["| Location | Action | Target | Reason |", "|---|---|---|---|"]
            for f in sorted(rows, key=lambda x: (x["file"], x["start"])):
                out.append("| %s | %s | %s | %s |" % (cell(loc(f)), f["action"], cell(f.get("target") or "—"), cell(f["reason"])))
        else:
            out.append("No findings to act on.")
        if kept:
            out.append("")
            out.append("%d reviewed passage(s) kept — see What NOT to change." % kept)
        out.append("")
    out += ["## Words removable (words on affected lines)", "", "| Level | Cut | Merge | Removed (cut+merge, ranges merged) | Moved |", "|---|---|---|---|---|"]
    for lvl in range(r["from"], r["stop_at"] + 1):
        p = r["per_level"][lvl]
        out.append("| %d %s | %d | %d | %d | %d |" % (lvl, LEVEL_NAMES[lvl - 1], p["cut"], p["merge"], p["removed"], p["moved"]))
    out += ["| **Total** | | | **%d** | %d |" % (r["total_removed"], r["total_moved"]), "", "_" + r["note"] + "._", ""]
    c = r["coverage"]
    out += ["## Coverage", "",
            "- File-levels reviewed: %d of %d" % (c["file_levels_reviewed"], c["file_levels_expected"]),
            "- Pairs reviewed: %d; unreviewed: %d" % (len(c["pairs"]["reviewed"]), len(c["pairs"]["unreviewed"]))]
    for lvl, n in sorted(c["pairs"].get("omitted_by_limit", {}).items()):
        if n:
            out.append("- Level %s candidate pairs omitted by the pair limit (never briefed): %d" % (lvl, n))
    for u in c["file_levels_unreviewed"][:50]:
        out.append("  - unreviewed: %s level %d" % (u["file"], u["level"]))
    for u in c["pairs"]["unreviewed"][:50]:
        out.append("  - unreviewed pair (level %s): %s" % (u["level"], " <-> ".join(u["pair"])))
    for x in r["excluded"]:
        out.append("  - excluded: %s (%s)" % (x["path"], x["reason"]))
    out += ["", "Unreviewed means unknown, not clean.", "", "## Invalid findings (%d)" % len(r["invalid"]), ""]
    for x in r["invalid"]:
        out.append("- `%s` — %s" % (cell(json.dumps(x["finding"], sort_keys=True))[:300], "; ".join(x["errors"])))
    out += ["", "## Conflicts with a keep (%d)" % len(r["conflicts"]), "",
            "Proposals that overlap a passage another finding keeps. Excluded from the tallies and from filing until resolved.", ""]
    for f in r["conflicts"]:
        out.append("- %s (level %d, %s) — %s" % (loc(f), f["level"], f["action"], cell(f["reason"])))
    upf = r.get("unreviewed_pair_findings", [])
    out += ["", "## Pair findings without a reviewed pair (%d)" % len(upf), "",
            "No \"reviewed\" coverage line for the pair. Excluded from the tallies and from filing.", ""]
    for f in upf:
        out.append("- %s (level %d, %s) — %s" % (loc(f), f["level"], f["action"], cell(f["reason"])))
    keeps =[f for f in r["findings"] if f["action"] == "keep"]
    out += ["", "## What NOT to change (%d)" % len(keeps), ""]
    for f in keeps:
        out.append("- %s (level %d) — %s" % (loc(f), f["level"], cell(f["reason"])))
    out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(prog="mdaudit.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("levels")
    p.add_argument("--kind", required=True, choices=["file", "folder", "repo"])
    p.add_argument("--from", dest="from_level")
    p.add_argument("--stop-at")
    p = sub.add_parser("inventory")
    p.add_argument("--target")
    p = sub.add_parser("segment")
    p.add_argument("--snapshot", required=True)
    p.add_argument("files", nargs="*")
    p = sub.add_parser("pairs")
    p.add_argument("--snapshot", required=True)
    p.add_argument("--level", required=True, choices=["6", "7"])
    p.add_argument("--limit", type=int, default=PAIR_LIMIT)
    p.add_argument("--min-shingles", type=int, default=2)
    p.add_argument("--min-identifiers", type=int, default=4)
    p = sub.add_parser("fingerprint")
    p.add_argument("--snapshot", required=True)
    p = sub.add_parser("verify-unchanged")
    p.add_argument("--snapshot", required=True)
    p.add_argument("--before", required=True)
    p = sub.add_parser("report")
    p.add_argument("--snapshot", required=True)
    p.add_argument("--findings", required=True)
    p.add_argument("--coverage")
    p.add_argument("--pairs", action="append", default=[])
    p.add_argument("--from", dest="from_level")
    p.add_argument("--stop-at")
    p.add_argument("--format", choices=["md", "json"], default="md")
    args = ap.parse_args()
    if args.cmd == "levels":
        lo, hi = level_range(args.kind, args.from_level, args.stop_at)
        print("%d %d" % (lo, hi))
    elif args.cmd == "inventory":
        cmd_inventory(args)
    elif args.cmd == "segment":
        cmd_segment(args)
    elif args.cmd == "pairs":
        cmd_pairs(args)
    elif args.cmd == "fingerprint":
        cmd_fingerprint(args)
    elif args.cmd == "verify-unchanged":
        cmd_verify(args)
    elif args.cmd == "report":
        cmd_report(args)
    else:
        ap.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()
