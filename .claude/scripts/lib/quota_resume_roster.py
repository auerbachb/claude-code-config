"""Local, metadata-only roster for manual Claude resume after a checkpoint."""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z", re.I)
LAUNCHER = re.compile(r"claude-[a-z0-9]+(?:-[a-z0-9]+)*\Z")
ACCOUNT_LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@+\-]{0,127}\Z")
KINDS = ("end", "usage-limit-park")


def physical_directory(path):
    if not isinstance(path, str) or any(ord(ch) < 32 for ch in path):
        raise ValueError("invalid directory")
    value = Path(path)
    if not value.is_absolute() or not value.is_dir():
        raise ValueError("directory is unavailable")
    return value.resolve(strict=True)


def metadata(setup):
    result = subprocess.run([str(setup), "launchers", "--json"], capture_output=True,
                            text=True, timeout=20, check=True)
    rows = json.loads(result.stdout)
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError("launcher registry is unreadable")
    return [row for row in rows if row.get("provider") == "claude"]


def registered_accounts(rows):
    accounts = {}
    profiles = set()
    launchers = set()
    for row in rows:
        label, name = row.get("label"), row.get("launcher")
        if (not isinstance(label, str) or not ACCOUNT_LABEL.fullmatch(label)
                or not isinstance(name, str) or not LAUNCHER.fullmatch(name)
                or label in accounts or name in launchers):
            raise ValueError("Claude launcher mapping is ambiguous or invalid")
        try:
            profile = physical_directory(row.get("profile_dir"))
        except (OSError, ValueError):
            profile = None
        if profile is not None:
            if profile in profiles:
                raise ValueError("more than one Claude account maps to the same profile")
            profiles.add(profile)
        accounts[label] = (name, profile)
        launchers.add(name)
    return accounts


def primary_account_email(home):
    path = home / ".claude.json"
    if path.is_symlink() or not path.is_file():
        return None
    try:
        result = subprocess.run(["jq", "-er", '.oauthAccount.emailAddress | strings', str(path)],
                                capture_output=True, text=True, timeout=5, check=True)
        value = result.stdout.strip()
        return value if "@" in value and ACCOUNT_LABEL.fullmatch(value) else None
    except (OSError, subprocess.SubprocessError):
        return None


def source_account(accounts, path, primary_email=None):
    source = physical_directory(path)
    labels = [label for label, (_, profile) in accounts.items() if profile == source]
    if not labels and primary_email:
        # The desktop primary can share projects with an isolated launcher
        # profile. Use the same account metadata as the reserve guard.
        labels = [label for label in accounts if label.casefold() == primary_email.casefold()]
    if len(labels) != 1:
        raise ValueError("the current Claude profile has no unique registered account")
    return labels[0], source


def roster_path(home, write=False):
    # Never follow a custom symlink into a checkout or a consumer repository.
    path = home
    for component in (".claude", "handoffs", "claude-resume-roster"):
        path = path / component
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise ValueError("the local resume roster directory is not safe")
        if write and ((path / ".git").exists() or (path / ".git").is_symlink()):
            raise ValueError("the local resume roster must stay outside a project checkout")
    if write and ((home / ".git").exists() or (home / ".git").is_symlink()):
        # A home dotfiles repository is common. Its private state may be
        # written only when the roster is ignored and nothing in it is tracked.
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        prefix = ["git", "-C", str(home)]
        relative = str(path.relative_to(home))
        tracked = subprocess.run([*prefix, "ls-files", "--", relative], capture_output=True,
                                 timeout=5, check=True, env=env).stdout
        ignored = subprocess.run([*prefix, "check-ignore", "--quiet", "--", relative + "/"],
                                 capture_output=True, timeout=5, env=env).returncode
        if tracked or ignored != 0:
            raise ValueError("the resume roster must be ignored by the home dotfiles repository")
    return path


def local_handoff(value, root):
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError("the verified handoff file is unavailable")
    actual = path.resolve(strict=True)
    if root.parent not in actual.parents or root in actual.parents:
        raise ValueError("the handoff must be a local file under ~/.claude/handoffs")
    return actual


def record(root, source, profile, session, cwd, summary, kind, handoff):
    if not SESSION_ID.fullmatch(session) or kind not in KINDS:
        raise ValueError("a verified Claude session ID and checkpoint type are required")
    item = {
        "session_id": session.lower(), "cwd": str(physical_directory(cwd)),
        "source_account": source, "source_profile": str(profile),
        "summary": " ".join(summary.split())[:180] or "not recorded", "checkpoint": kind,
        "handoff": str(local_handoff(handoff, root)),
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    }
    root.mkdir(mode=0o700, exist_ok=True)
    path = root / (item["session_id"] + ".json")
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=root, delete=False) as tmp:
        name = tmp.name
        try:
            json.dump(item, tmp, ensure_ascii=False)
            tmp.write("\n")
            tmp.flush()
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    return item


def shared_projects(profile):
    if profile is None:
        return None
    try:
        return physical_directory(str(profile / "projects"))
    except (OSError, ValueError):
        return None


def has_transcript(projects, session):
    if projects is None:
        return False
    # Stat only the exact transcript filename; never read transcript content.
    try:
        matches = [p for p in projects.glob(f"*/{session}.jsonl")
                   if not p.is_symlink() and p.is_file()
                   and p.resolve(strict=True).parent.parent == projects]
    except OSError:
        return False
    return len(matches) == 1


def quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"


def read_park_records(state_helper):
    # The caller expressly requested the account-wide roster. Filter the
    # canonical read in-process; no other state or transcript reaches stdout.
    try:
        result = subprocess.run([str(state_helper), "--session-view", "--all-repos"],
                                capture_output=True, text=True, timeout=20, check=True)
        rows = json.loads(result.stdout)["repos"]
        if not isinstance(rows, dict):
            raise ValueError("invalid repository map")
        records = []
        for repo in rows.values():
            prs = repo.get("prs", {}) if isinstance(repo, dict) else {}
            if not isinstance(prs, dict):
                continue
            for pr in prs.values():
                if not isinstance(pr, dict) or pr.get("handoff_reason") != "usage_limit_park":
                    continue
                park = pr.get("usage_limit_park")
                if isinstance(park, dict) and isinstance(park.get("quota_resume"), dict):
                    records.append(park["quota_resume"])
        return records, "read"
    except (KeyError, OSError, subprocess.SubprocessError, TypeError, ValueError):
        return [], "unavailable"


def end_records(root):
    rows, invalid = [], 0
    for path in sorted(root.glob("*.json")):
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 16384:
                raise ValueError("invalid record file")
            item = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(item, dict) or path.name != str(item.get("session_id")) + ".json":
                raise ValueError("invalid record")
            rows.append(item)
        except (OSError, ValueError):
            invalid += 1
    return rows, invalid


def list_records(root, accounts, source, profile, parked=(), park_lookup="not requested"):
    projects = shared_projects(profile)
    end, invalid = end_records(root)
    entries, conflicts = {}, set()
    # An explicit, verified /end record takes precedence for the same
    # conversation. A single park can have one record per parked PR.
    for item in [*end, *parked]:
        try:
            kind = item.get("checkpoint")
            item_profile = physical_directory(item.get("source_profile"))
            if item_profile != profile:
                continue
            if kind == "end" and item.get("source_account") != source:
                raise ValueError("record identity changed")
            sid = item["session_id"]
            if not isinstance(sid, str) or not SESSION_ID.fullmatch(sid) or kind not in KINDS:
                raise ValueError("record identity changed")
            sid = sid.lower()
            cwd = physical_directory(item["cwd"])
            handoff = local_handoff(item["handoff"], root)
            if sid in entries:
                if entries[sid]["cwd"] != str(cwd):
                    conflicts.add(sid)
                continue
            summary = item["summary"]
            if not isinstance(summary, str) or summary != " ".join(summary.split()) or len(summary) > 180:
                raise ValueError("invalid summary")
            transcript = has_transcript(projects, sid)
            options = []
            for label, (launcher, target) in accounts.items():
                if label == source:
                    continue
                if transcript and projects == shared_projects(target):
                    options.append({"target_account": label, "status": "portable",
                                    "command": f"cd -- {quote(str(cwd))} && {launcher} --resume {quote(sid)}"})
                else:
                    options.append({"target_account": label, "status": "not portable", "handoff": str(handoff)})
            entries[sid] = {"session_id": sid, "cwd": str(cwd), "source_account": source,
                            "summary": summary, "checkpoint": kind,
                            "handoff": str(handoff), "options": options}
        except (KeyError, OSError, TypeError, ValueError):
            invalid += 1
    for sid in conflicts:
        entry = entries[sid]
        entry["options"] = [{"target_account": option["target_account"],
                             "status": "not portable", "handoff": entry["handoff"]}
                            for option in entry["options"]]
    return {"entries": list(entries.values()), "unreadable_records": invalid + len(conflicts),
            "park_lookup": park_lookup,
            "precondition": "Close the original Claude session before running a resume command."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("list", help="list recorded sessions for the current registered Claude profile")
    add = sub.add_parser("record", help="record an already verified end or park checkpoint")
    add.add_argument("--session", required=True)
    add.add_argument("--cwd", required=True)
    add.add_argument("--summary", required=True)
    add.add_argument("--kind", choices=KINDS, required=True)
    add.add_argument("--handoff", required=True)
    args = parser.parse_args()
    try:
        home = Path.home().resolve(strict=True)
        root = roster_path(home, write=args.action == "record")
        setup = Path(__file__).resolve().parents[1] / "ai-quotas-setup.sh"
        accounts = registered_accounts(metadata(setup))
        primary = home / ".claude"
        configured = os.environ.get("CLAUDE_CONFIG_DIR") or str(primary)
        try:
            source, profile = source_account(accounts, configured)
        except ValueError:
            if physical_directory(configured) != primary:
                raise
            source, profile = source_account(accounts, configured, primary_account_email(home))
        if args.action == "record":
            record(root, source, profile, args.session, args.cwd, args.summary, args.kind, args.handoff)
        parked, park_lookup = read_park_records(setup.with_name("session-state.sh"))
        print(json.dumps(list_records(root, accounts, source, profile, parked, park_lookup),
                         ensure_ascii=False))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        # A failed helper can contain private registry details in stderr.
        detail = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "metadata unavailable"
        print(f"quota-resume-roster: {detail}", file=sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
