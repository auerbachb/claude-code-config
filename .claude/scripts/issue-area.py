#!/usr/bin/env python3
# catalog: utilities — Resolve configured issue areas and tag declared paths for launch overlap.
"""Resolve configured launch-side areas for one ranked issue batch."""

import argparse
import json
import re
import sys
from pathlib import Path


HEADER = ("Area", "Paths", "Labels", "Keywords")
AREA = re.compile(r"[a-z][a-z0-9-]*\Z")
GLOB = re.compile(r"[a-zA-Z0-9._/*?-]+\Z")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
HEADING = re.compile(r"^## (.+?)\s*$")


def entries(value):
    if not value or value == "—":
        return []
    parts = [part.strip().strip("`") for part in value.split(",")]
    if not all(parts):
        raise ValueError("empty comma-separated field")
    return parts


def path_pattern(glob):
    if (not GLOB.fullmatch(glob) or glob.startswith("/")
            or any(part in ("", ".", "..") for part in glob.rstrip("/").split("/"))):
        raise ValueError("area globs must be repository-relative paths")
    if glob.endswith("/"):
        glob += "*"
    tokens = re.split(r"(\*\*/|\*+|\?)", glob)
    special = {"**/": "(?:.*/)?", "?": "."}
    return re.compile("".join(special.get(token, ".*" if token.startswith("*")
                                          else re.escape(token)) for token in tokens))


def live_lines(text):
    """Ignore examples before looking for their section boundaries."""
    fence = None
    in_comment = False
    for line in text.splitlines():
        if fence:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{"
                            + str(len(fence)) + r",}[ \t]*", line):
                fence = None
            continue
        if not in_comment:
            if line.startswith(("    ", "\t")):
                continue
            opening = FENCE.fullmatch(line)
            if opening:
                marker, tail = opening.groups()
                if marker[0] == "~" or "`" not in tail:
                    fence = marker
                    continue
        visible = ""
        while line:
            if in_comment:
                _, closing, line = line.partition("-->")
                if not closing:
                    break
                in_comment = False
            else:
                prefix, opening, line = line.partition("<!--")
                visible += prefix
                if not opening:
                    break
                in_comment = True
        yield visible
    if in_comment:
        raise ValueError("unclosed HTML comment in area configuration")


def area_section(config):
    found = False
    active = False
    section = []
    for line in live_lines(config):
        heading = HEADING.fullmatch(line)
        if heading:
            active = heading[1] == "Independent areas"
            if active and found:
                raise ValueError("duplicate Independent areas section")
            found = found or active
        elif active:
            section.append(line)
    return "\n".join(section)


def load_areas(section):
    lines = []
    table_finished = False
    for line in section.splitlines():
        if line.lstrip().startswith("|"):
            if table_finished:
                raise ValueError("expected one contiguous Independent areas table")
            lines.append(line.strip())
        elif lines:
            table_finished = True
    if not lines:
        return {}
    table = [tuple(field.strip() for field in line[1:].removesuffix("|").split("|")) for line in lines]
    if (len(table) < 2 or table[0] != HEADER or len(table[1]) != len(HEADER)
            or not all(re.fullmatch(r":?-{3,}:?", cell) for cell in table[1])):
        raise ValueError("expected the Independent areas table header")
    areas = {}
    for row in table[2:]:
        if len(row) != len(HEADER):
            raise ValueError("invalid Independent areas table row")
        name, globs, labels, keywords = row
        name = name.casefold()
        if not AREA.fullmatch(name) or name in areas:
            raise ValueError("area names must be unique slugs")
        patterns = [path_pattern(glob) for glob in entries(globs)]
        if not patterns:
            raise ValueError("each area must have at least one path glob")
        areas[name] = (
            patterns,
            {label.casefold() for label in entries(labels)},
            [re.compile(r"(?<![\w-])" + re.escape(word.casefold()) + r"(?![\w-])")
             for word in entries(keywords)],
        )
    return areas


def footprint(areas, issue):
    paths = issue.get("paths", [])
    if not isinstance(paths, list) or not all(isinstance(path, str) and path for path in paths):
        raise ValueError("paths must be an array of normalized path strings")
    if paths:
        return {
            "area": None,
            "source": None,
            "path_areas": [name for name, (globs, _, _) in areas.items()
                           if any(glob.fullmatch(path) for path in paths for glob in globs)],
        }
    labels = issue.get("labels")
    title, body = issue.get("title"), issue.get("body")
    if (not isinstance(labels, list) or not all(isinstance(label, str) for label in labels)
            or not isinstance(title, str) or not isinstance(body, str)):
        raise ValueError("pathless issue requires complete labels, title and body")
    label_set = {label.casefold() for label in labels}
    matches = [name for name, (_, hints, _) in areas.items() if hints & label_set]
    source = "label"
    if not matches:
        source = "keyword"
        text = f"{title}\n{body}".casefold()
        matches = [name for name, (_, _, hints) in areas.items()
                   if any(hint.search(text) for hint in hints)]
    unique = len(matches) == 1
    return {"area": matches[0] if unique else None,
            "source": source if unique else None, "path_areas": []}


def evaluate(areas, issues):
    if not isinstance(issues, list):
        raise ValueError("expected an issue array")
    results = {}
    for issue in issues:
        if (not isinstance(issue, dict) or type(issue.get("number")) is not int
                or issue["number"] <= 0 or issue["number"] in results):
            raise ValueError("issues require unique positive numbers")
        results[issue["number"]] = footprint(areas, issue)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, default=Path(".claude/pm-config.md"))
    parser.add_argument("--config-only", action="store_true",
                        help="report whether valid active areas are configured")
    options = parser.parse_args()
    try:
        try:
            section = area_section(options.file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            if options.file.exists() or options.file.is_symlink():
                raise
            section = ""
        areas = load_areas(section)
        output = {"enabled": bool(areas)}
        if not options.config_only:
            output["issues"] = evaluate(areas, json.load(sys.stdin))
        print(json.dumps(output, separators=(",", ":")))
    except (OSError, ValueError) as error:
        print(f"issue-area: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
