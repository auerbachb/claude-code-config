"""Account-scoped advisory reset records; no credential or provider access."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time


class ResetError(ValueError):
    pass


def warn(message):
    print("Codex reset: " + message, file=sys.stderr)


def load(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise ResetError("unsafe record file")
        data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ResetError("record exceeds size bound")
        return json.loads(data)


def valid_record(record):
    if not isinstance(record, dict):
        return False
    month, day = record.get("month"), record.get("used_on")
    if not isinstance(month, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}", month):
        return False
    if not isinstance(day, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", day):
        return False
    try:
        return datetime.date.fromisoformat(day).isoformat() == day and day[:7] == month
    except ValueError:
        return False


def records(document):
    if document is None:
        return {}
    if not isinstance(document, dict):
        raise ResetError("unreadable watermark")
    if document.get("schema_version") == "1.0" and valid_record(document):
        warn("legacy global watermark belongs to no account; assuming free resets available")
        return {}
    if document.get("schema_version") != "2.0" or not isinstance(document.get("accounts"), dict):
        raise ResetError("unreadable watermark schema")
    return document["accounts"]


def verdict(record, month):
    assumed = {"free_reset_available": True, "figure_source": "assumed", "used_on": None}
    if not month or record is None:
        return assumed
    if not valid_record(record):
        warn("unreadable account record; assuming its free reset available")
        return assumed
    return {"free_reset_available": record["month"] != month,
            "figure_source": "watermark", "used_on": record["used_on"] if record["month"] == month else None}


def labels(path):
    document = load(path)
    if document is None:
        return []
    if (not isinstance(document, dict) or document.get("schema_version") != "1.0"
            or not isinstance(document.get("accounts"), list)):
        raise ResetError("unreadable account registry")
    result = []
    for row in document["accounts"]:
        if not isinstance(row, dict) or not isinstance(row.get("provider"), str):
            raise ResetError("unreadable account registry")
        if row["provider"] != "codex":
            continue
        label = row.get("label")
        if not isinstance(label, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._@+\-]{0,127}", label) or label in result:
            raise ResetError("invalid or duplicate Codex account label")
        result.append(label)
    return result


def write(args):
    if args.label not in labels(args.registry):
        raise ResetError("name a registered Codex label with --account")
    parent = args.file.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = parent.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise ResetError("unsafe watermark directory")
    fd = os.open(str(args.file) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "a") as lock:
        metadata = os.fstat(lock.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise ResetError("unsafe watermark lock")
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ResetError("watermark lock busy; retry the recording")
                time.sleep(.05)
        accounts = records(load(args.file))
        previous = accounts.get(args.label)
        if valid_record(previous) and args.day[:7] < previous["month"]:
            raise ResetError("refusing to replace this account's recorded watermark with an older month")
        accounts[args.label] = {"month": args.day[:7], "used_on": args.day,
                                "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        payload = json.dumps({"schema_version": "2.0", "accounts": accounts}, ensure_ascii=False) + "\n"
        if len(payload.encode()) > 1024 * 1024:
            raise ResetError("record exceeds size bound")
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=parent, delete=False) as stream:
                temporary = stream.name
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, args.file)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("read", "status", "record"))
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--registry", type=Path)
    parser.add_argument("--month", default="")
    parser.add_argument("--day", default="")
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    try:
        if args.mode == "record":
            if not args.registry or not args.label or not valid_record({"month": args.day[:7], "used_on": args.day}):
                raise ResetError("recording requires a registered account and valid date")
            write(args)
            return 0
        try:
            accounts = records(load(args.file))
        except (OSError, ValueError, UnicodeError):
            warn("unreadable watermark; assuming free resets available")
            accounts = {}
        selected = labels(args.registry) if args.mode == "status" and args.registry else accounts
        result = {label: verdict(accounts.get(label), args.month) for label in selected}
        if args.mode == "status":
            print(json.dumps({"month": args.month, "accounts": result, "watermark_file": str(args.file)}))
        else:
            print(json.dumps(result))
        return 0
    except ResetError as exc:
        warn(str(exc))
        return 5
    except (OSError, ValueError, UnicodeError):
        # Never echo untrusted file contents, credentials or account labels.
        warn("could not verify or persist reset state; check registry, watermark and lock (older-month replacement is refused)")
        return 5


if __name__ == "__main__":
    sys.exit(main())
