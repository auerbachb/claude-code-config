"""Derive only fully observed, homogeneous Claude Keychain cycles.

Input is registry metadata. Sidecars contain service names, never credentials.
No Keychain APIs, credential files, or item data are read here.
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import unicodedata


def service(path):
    raw = unicodedata.normalize("NFC", path).encode("utf-8")
    return "Claude Code-credentials-" + hashlib.sha256(raw).hexdigest()[:8]


def managed_mismatch(row, root):
    """Match doctor's managed label mismatches; leave custom paths untouched."""
    if row["provider"] != "claude":
        return False
    source = row["profile_dir"]
    prefix, suffix = f"{root}/", "/claude"
    if not source.startswith(prefix) or not source.endswith(suffix):
        return False
    path_label = source[len(prefix):-len(suffix)]
    target = f"{root}/{row['label']}/claude"
    return (bool(path_label) and "/" not in path_label
            and path_label != row["label"]
            and os.path.realpath(source) != os.path.realpath(target))


def cycle(config, root):
    if "CLAUDE_SECURESTORAGE_CONFIG_DIR" in os.environ:
        return []
    rows = [
        row for row in config["accounts"]
        if managed_mismatch(row, root)
    ]
    if not rows:
        return []
    sources = [row["profile_dir"] for row in rows]
    targets = [f"{root}/{row['label']}/claude" for row in rows]
    if len(set(sources)) != len(rows) or set(sources) != set(targets):
        return []
    if len({row.get("credential_ref", {}).get("service") for row in rows}) != len(rows):
        return []
    result = []
    for row, target in zip(rows, targets):
        source = row["profile_dir"]
        path = Path(source)
        sidecar = path.parent / ".keychain-service-claude"
        recorded = row.get("credential_ref", {}).get("service")
        credential = path / ".credentials.json"
        if (credential.exists() or credential.is_symlink()
                or not sidecar.is_file() or sidecar.is_symlink()
                or recorded != service(source)
                or sidecar.read_text().strip() != recorded):
            return []
        result.append({"label": row["label"], "service": recorded,
                       "target_service": service(target),
                       "api_service": "Claude Code-" + recorded.rsplit("-", 1)[1]})
    return result


if __name__ == "__main__":
    try:
        print(json.dumps(cycle(json.load(sys.stdin), sys.argv[1]), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, IndexError, AttributeError):
        print("[]")
