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


def cycle(config, root):
    if "CLAUDE_SECURESTORAGE_CONFIG_DIR" in os.environ:
        return []
    rows = [
        row for row in config["accounts"]
        if row["provider"] == "claude"
        and row["profile_dir"] != f"{root}/{row['label']}/claude"
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
