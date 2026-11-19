#!/usr/bin/env bash
# Check the desk operating manual index and incoming links.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
from collections import Counter
from functools import lru_cache
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

root = Path(sys.argv[1]).resolve()
readme = root / "desk/README.md"
docs = root / "desk/docs"
text = readme.read_text(encoding="utf-8")
destination = r"(<[^<>\n]+>|[^\s)]+)"
inline_link = re.compile(r"\]\(\s*" + destination + r"(?=[\s)])")
reference_link = re.compile(r"^ {0,3}\[[^\]\n]+\]:[ \t]*(?:\n[ \t]*)?" + destination, re.M)
reference = re.compile(r"`(desk/(?:README\.md|docs/[^\s`#]+\.md)(?:#[^\s`]+)?)`")
index = re.findall(r"<!-- desk-docs-index:start -->(.*?)<!-- desk-docs-index:end -->", text, re.S)
errors = []


def markdown_lines(body):
    fence = ""
    for line in body.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if marker:
            token, rest = marker.groups()
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence) and not rest.strip(" \t"):
                fence = ""
            continue
        if not fence:
            yield line


def link_targets(body):
    content = "\n".join(markdown_lines(body))
    for pattern in (inline_link, reference_link):
        for target in pattern.findall(content):
            yield target[1:-1] if target.startswith("<") else target


if len(index) != 1:
    errors.append("desk/README.md must contain one desk-docs index")
else:
    indexed = Counter(target for target in link_targets(index[0]) if "#" not in target)
    expected = {f"docs/{path.name}" for path in docs.glob("*.md")}
    if not expected:
        errors.append("desk/docs contains no feature documents")
    for target in sorted(expected | set(indexed)):
        count = indexed[target]
        if target not in expected:
            errors.append(f"desk/README.md indexes an absent feature file {target}")
        elif count != 1:
            errors.append(f"desk/README.md must index {target} exactly once (found {count})")


@lru_cache(maxsize=None)
def fragments(path):
    anchors = set()
    counts = Counter()
    for line in markdown_lines(path.read_text(encoding="utf-8")):
        anchors.update(re.findall(r'<a (?:name|id)="([^"]+)"', line))
        heading = re.match(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?$", line)
        if heading:
            slug = re.sub(r"[^\w -]", "", heading[1].lower()).replace(" ", "-")
            anchors.add(f"{slug}-{counts[slug]}" if counts[slug] else slug)
            counts[slug] += 1
    return anchors


def check_target(source, target, repository_relative=False):
    if target.startswith("//") or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):
        return
    url = urlsplit(target)
    if repository_relative or url.path.startswith("/"):
        path = root / unquote(url.path.lstrip("/"))
    elif url.path:
        path = source.parent / unquote(url.path)
    else:
        path = source
    path = path.resolve()
    if path != readme and docs not in path.parents:
        return
    location = source.relative_to(root)
    if not path.is_file():
        errors.append(f"{location} links to missing desk documentation {target}")
    elif url.fragment and unquote(url.fragment) not in fragments(path):
        errors.append(f"{location} links to missing desk fragment {target}")


tracked = subprocess.check_output(
    ["git", "ls-files", "-z", "--", ".claude", "desk", "tests", ".github"], cwd=root
).decode().split("\0")
sources = {root / name for name in tracked if Path(name).suffix in {".md", ".py", ".sh"}}
for source in sorted(sources | {readme} | set(docs.glob("*.md"))):
    if not source.is_file():
        continue
    body = source.read_text(encoding="utf-8")
    if source.suffix == ".md":
        for target in link_targets(body):
            check_target(source, target)
    for target in reference.findall(body):
        check_target(source, target, repository_relative=True)

for error in sorted(set(errors)):
    print(error, file=sys.stderr)
if errors:
    sys.exit(1)
print(f"desk-docs-index-lint: {len(list(docs.glob('*.md')))} feature documents indexed")
PY
