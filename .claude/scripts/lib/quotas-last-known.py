"""Last-known usage readings: one private file per account (issue #2280).

The only code that touches the last-known folder. Usage percentages, reset
times and account labels are stored; no credential, cookie, token or provider
payload ever is. Display only: nothing that gates dispatch may call this.

  record      stdin {"accounts":[...]}: replace each account's file with its
              usable live rows. A file holding a reading newer than the
              incoming one is left alone.
  owner-report  upsert one owner-typed series, keeping the account's other rows.
  lookup      stdin JSON lines {"provider","label"}: print each saved series
              with its effective reset and an expiry flag. Never writes.

Exit codes: 0 ok, 3 usage, 5 unsafe or unwritable folder, 7 lock contention.
Warnings go to stderr and never echo file contents.
"""
import argparse
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time

PROVIDERS = ("claude", "codex", "cursor")
LABEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@+\-]{0,127}")
CURSOR_POOLS = ("cursor-models", "other-models")
SCHEMA = "last-known/1"
MAX_BYTES = 1024 * 1024
LOCK_SECONDS = 5
# owner-report found a newer saved reading for the same series and kept it.
RETAINED_NEWER = 9


class LastKnownError(Exception):
    """A refusal that names the problem without echoing file contents."""

    def __init__(self, message, code=5):
        super().__init__(message)
        self.code = code


def warn(message):
    print("last-known: " + message, file=sys.stderr)


def valid_identity(provider, label):
    return provider in PROVIDERS and isinstance(label, str) and LABEL_RE.fullmatch(label) is not None


def usable_pct(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def secure_folder(folder, create):
    """Refuse symlinks, foreign owners and world-writable folders; tighten to 0700."""
    if create:
        os.makedirs(folder.parent, exist_ok=True)
        if not folder.exists() and not folder.is_symlink():
            # Another helper may create the folder between the check and the
            # mkdir; that is success. The checks below still vet what exists.
            try:
                os.mkdir(folder, 0o700)
            except FileExistsError:
                pass
    try:
        metadata = folder.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise LastKnownError("unsafe last-known folder (not a private directory)")
    if metadata.st_mode & 0o002:
        raise LastKnownError("unsafe last-known folder (world-writable)")
    if metadata.st_mode & 0o777 != 0o700:
        os.chmod(folder, 0o700)
    return True


def read_json(path):
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError:
        raise LastKnownError("unreadable or linked account file")
    with os.fdopen(fd, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise LastKnownError("unsafe account file")
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise LastKnownError("account file exceeds size bound")
    try:
        document = json.loads(data)
    except ValueError:
        raise LastKnownError("malformed account file")
    if not isinstance(document, dict):
        raise LastKnownError("malformed account file")
    return document


def eastern_zone():
    """America/New_York from the system tz database; a fixed EST offset when that database is absent."""
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("America/New_York")
    except Exception:
        return datetime.timezone(datetime.timedelta(hours=-5))


def eastern_midnight(day):
    return int(day.replace(tzinfo=eastern_zone()).timestamp())


def parse_reset_date(text):
    """Stopgap reset text without an epoch, e.g. 'Nov 28 2026': midnight Eastern, else None."""
    if not isinstance(text, str):
        return None
    try:
        return eastern_midnight(datetime.datetime.strptime(text.strip(), "%b %d %Y"))
    except ValueError:
        return None


def resolve_reset(text):
    """Owner-typed reset: epoch seconds, YYYY-MM-DD (midnight Eastern), a full ISO-8601 timestamp, or 'Mon DD YYYY'."""
    if text is None or text.strip() == "":
        return None
    value = text.strip()
    if re.fullmatch(r"[0-9]{9,11}", value):
        return int(value)
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        try:
            return eastern_midnight(datetime.datetime.strptime(value, "%Y-%m-%d"))
        except ValueError:
            raise LastKnownError("reset is not a real calendar date", code=3)
    parsed = parse_reset_date(value)
    if parsed is not None:
        return parsed
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise LastKnownError("reset must be YYYY-MM-DD, an ISO-8601 timestamp, or epoch seconds", code=3)
    if moment.tzinfo is None:
        return int(moment.replace(tzinfo=eastern_zone()).timestamp())
    return int(moment.timestamp())


def normalise_rows(document, provider, label):
    """Series rows with provenance and pools resolved. Malformed rows are skipped."""
    file_source = document.get("source") if isinstance(document.get("source"), str) else None
    file_fetched = document.get("fetched_at_epoch")
    series = []
    rows = document.get("rows")
    if not isinstance(rows, list):
        return series
    for row in rows:
        if not isinstance(row, dict) or not usable_pct(row.get("used_pct")):
            continue
        window = row.get("window") if isinstance(row.get("window"), str) else None
        pool = row.get("pool") if isinstance(row.get("pool"), str) else None
        if provider == "cursor" and pool is None and window in CURSOR_POOLS:
            pool = window
        if window is None:
            window = pool
        if not window:
            continue
        resets_at = row.get("resets_at_epoch")
        if not isinstance(resets_at, int) or isinstance(resets_at, bool):
            resets_at = None
        resets_text = row.get("resets") if isinstance(row.get("resets"), str) else None
        fetched = row.get("fetched_at_epoch", file_fetched)
        if not isinstance(fetched, int) or isinstance(fetched, bool):
            fetched = None
        source = row.get("source") if isinstance(row.get("source"), str) else file_source
        overage = row.get("overage") if isinstance(row.get("overage"), dict) else None
        series.append({
            "window": window,
            "pool": pool,
            "used_pct": row["used_pct"],
            "resets_at_epoch": resets_at,
            "resets": resets_text,
            "overage": overage,
            "source": source,
            "fetched_at_epoch": fetched,
        })
    return series


def newest_epoch(series):
    values = [row["fetched_at_epoch"] for row in series if row["fetched_at_epoch"] is not None]
    return max(values) if values else None


def write_account(folder, provider, label, document):
    path = folder / (provider + "--" + label + ".json")
    payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    if len(payload.encode()) > MAX_BYTES:
        raise LastKnownError("record exceeds size bound")
    if path.is_symlink():
        raise LastKnownError("refusing to replace a symbolic link")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=folder, delete=False) as stream:
            temporary = stream.name
            os.chmod(temporary, 0o600)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


class Lock:
    """Folder-wide advisory lock, reread under the lock (as quotas-codex-reset.py)."""

    def __init__(self, folder):
        self.path = folder / ".lock"
        self.stream = None

    def __enter__(self):
        fd = os.open(str(self.path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        self.stream = os.fdopen(fd, "a")
        metadata = os.fstat(self.stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            self.stream.close()
            raise LastKnownError("unsafe last-known lock file")
        deadline = time.monotonic() + LOCK_SECONDS
        while True:
            try:
                fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.stream.close()
                    raise LastKnownError("last-known lock busy; retry", code=7)
                time.sleep(0.05)

    def __exit__(self, *exc):
        self.stream.close()
        return False


def cmd_record(args):
    folder = Path(args.dir)
    try:
        document = json.loads(sys.stdin.read(MAX_BYTES + 1))
    except ValueError:
        raise LastKnownError("record input is not JSON", code=3)
    accounts = document.get("accounts") if isinstance(document, dict) else None
    if not isinstance(accounts, list):
        raise LastKnownError("record input has no accounts", code=3)
    secure_folder(folder, create=True)
    with Lock(folder):
        for account in accounts:
            if not isinstance(account, dict):
                continue
            provider, label = account.get("provider"), account.get("label")
            if not valid_identity(provider, label):
                warn("skipped an account with an invalid provider or label")
                continue
            try:
                existing = read_json(folder / (provider + "--" + label + ".json"))
                prior = normalise_rows(existing, provider, label) if existing else []
            except LastKnownError:
                prior = []  # an unreadable file is replaced by a usable live reading
            fetched = account.get("fetched_at_epoch")
            if not isinstance(fetched, int) or isinstance(fetched, bool):
                warn("skipped an account without a reading time")
                continue
            newest = newest_epoch(prior)
            if newest is not None and newest > fetched:
                warn("kept a newer saved reading for one account")
                continue
            rows = []
            for row in account.get("rows") or []:
                if not isinstance(row, dict) or not usable_pct(row.get("used_pct")):
                    continue
                if not isinstance(row.get("window"), str):
                    continue
                rows.append({
                    "window": row["window"],
                    "pool": row.get("pool") if isinstance(row.get("pool"), str) else None,
                    "used_pct": row["used_pct"],
                    "resets_at_epoch": row.get("resets_at_epoch") if isinstance(row.get("resets_at_epoch"), int) else None,
                    "resets": row.get("resets") if isinstance(row.get("resets"), str) else None,
                    "overage": row.get("overage") if isinstance(row.get("overage"), dict) else None,
                    "source": row.get("source") if isinstance(row.get("source"), str)
                    else account.get("source") if isinstance(account.get("source"), str) else None,
                    "fetched_at_epoch": fetched,
                })
            # A partial live read keeps the saved series it did not return,
            # so a failed window or pool never erases its last good reading.
            fresh_keys = {(row["window"], row["pool"]) for row in rows}
            rows += [saved for saved in prior if (saved["window"], saved["pool"]) not in fresh_keys]
            if not rows:
                continue
            nickname = account.get("nickname") if isinstance(account.get("nickname"), str) else None
            write_account(folder, provider, label, {
                "schema": SCHEMA,
                "provider": provider,
                "label": label,
                "nickname": nickname,
                "fetched_at_epoch": fetched,
                "fetched_at_et": account.get("fetched_at_et") if isinstance(account.get("fetched_at_et"), str) else None,
                "source": account.get("source") if isinstance(account.get("source"), str) else None,
                "rows": rows,
            })
    return 0


def cmd_owner_report(args):
    if not valid_identity(args.provider, args.label):
        raise LastKnownError("owner report needs a valid provider and label", code=3)
    folder = Path(args.dir)
    secure_folder(folder, create=True)
    with Lock(folder):
        existing = read_json(folder / (args.provider + "--" + args.label + ".json"))
        series = normalise_rows(existing, args.provider, args.label) if existing else []
        window, pool = args.window, args.pool or None
        for row in series:
            if (row["window"], row["pool"]) == (window, pool) and row["fetched_at_epoch"] is not None \
                    and row["fetched_at_epoch"] > args.now:
                warn("kept a newer saved reading for this series")
                return RETAINED_NEWER
        series = [row for row in series if (row["window"], row["pool"]) != (window, pool)]
        whole = float(args.used_pct).is_integer()
        series.append({
            "window": window, "pool": pool,
            "used_pct": int(args.used_pct) if whole else float(args.used_pct),
            "resets_at_epoch": resolve_reset(args.resets_text), "resets": args.resets_text or None,
            "overage": None, "source": "owner-reported", "fetched_at_epoch": args.now,
        })
        rows = [{"window": row["window"], "pool": row["pool"], "used_pct": row["used_pct"],
                 "resets_at_epoch": row["resets_at_epoch"], "resets": row["resets"],
                 "overage": row["overage"], "source": row["source"],
                 "fetched_at_epoch": row["fetched_at_epoch"]} for row in series]
        newest = max(row["fetched_at_epoch"] or 0 for row in rows)
        newest_row = next(row for row in rows if row["fetched_at_epoch"] == newest)
        write_account(folder, args.provider, args.label, {
            "schema": SCHEMA,
            "provider": args.provider,
            "label": args.label,
            "nickname": args.nickname or None,
            "fetched_at_epoch": newest,
            "fetched_at_et": args.now_et or None,
            "source": newest_row["source"],
            "rows": rows,
        })
    return 0


def cmd_forget(args):
    if not valid_identity(args.provider, args.label):
        raise LastKnownError("forget needs a valid provider and label", code=3)
    folder = Path(args.dir)
    if not folder.exists() and not folder.is_symlink():
        return 0
    secure_folder(folder, create=False)
    with Lock(folder):
        path = folder / (args.provider + "--" + args.label + ".json")
        if path.is_symlink():
            raise LastKnownError("refusing to remove a symbolic link")
        if path.exists():
            path.unlink()
    return 0


def cmd_lookup(args):
    folder = Path(args.dir)
    try:
        metadata = folder.lstat()
    except FileNotFoundError:
        return 0
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o002:
        warn("unsafe last-known folder; no saved figures read")
        return 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            warn("skipped a malformed lookup request")
            continue
        provider = request.get("provider") if isinstance(request, dict) else None
        label = request.get("label") if isinstance(request, dict) else None
        if not valid_identity(provider, label):
            continue
        try:
            document = read_json(folder / (provider + "--" + label + ".json"))
        except LastKnownError as exc:
            warn("skipped one saved file: " + str(exc))
            continue
        if document is None:
            continue
        for row in normalise_rows(document, provider, label):
            effective = row["resets_at_epoch"]
            if effective is None:
                effective = parse_reset_date(row["resets"])
            expired = effective is not None and effective <= args.now
            print(json.dumps({
                "provider": provider,
                "label": label,
                "window": row["window"],
                "pool": row["pool"],
                "used_pct": row["used_pct"],
                "fetched_at_epoch": row["fetched_at_epoch"],
                "source": row["source"],
                "resets_at_epoch": effective,
                "expired": expired,
            }, sort_keys=True))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    for name in ("record", "lookup", "owner-report", "forget"):
        p = sub.add_parser(name)
        p.add_argument("--dir", required=True)
        p.add_argument("--now", type=int, default=0)
        if name == "forget":
            p.add_argument("--provider", default="")
            p.add_argument("--label", default="")
        if name == "owner-report":
            p.add_argument("--provider", default="")
            p.add_argument("--label", default="")
            p.add_argument("--nickname", default="")
            p.add_argument("--window", default="")
            p.add_argument("--pool", default="")
            p.add_argument("--used-pct", type=float, default=None)
            p.add_argument("--resets-text", default="")
            p.add_argument("--now-et", default="")
    args = parser.parse_args(argv)
    try:
        if args.mode == "record":
            return cmd_record(args)
        if args.mode == "lookup":
            return cmd_lookup(args)
        if args.mode == "forget":
            return cmd_forget(args)
        if (not args.window or args.used_pct is None or not usable_pct(args.used_pct)
                or not 0 <= args.used_pct <= 100):
            raise LastKnownError("owner report needs a window and a usable percentage", code=3)
        args.now = args.now or int(time.time())
        return cmd_owner_report(args)
    except LastKnownError as exc:
        warn(str(exc))
        return exc.code
    except (OSError, ValueError, UnicodeError, StopIteration, KeyError, TypeError):
        warn("could not read or persist the last-known folder")
        return 5


if __name__ == "__main__":
    sys.exit(main())
