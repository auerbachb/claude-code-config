#!/usr/bin/env python3
"""Antigravity `/usage` panel parser, observation store and optional live capture.

Usage:
  quotas-antigravity.py parse   <text-file|-> <captured-epoch>
  quotas-antigravity.py ingest  <text-file|-> <captured-epoch> <via> <observation-file>
  quotas-antigravity.py show    <observation-file> <now-epoch>
  quotas-antigravity.py capture <agy-bin> <captured-epoch> <observation-file>
  quotas-antigravity.py backend <captured-epoch> <observation-file>
  quotas-antigravity.py parse-backend <json-file|-> <captured-epoch>
  quotas-antigravity.py terminal <agy-bin> <captured-epoch> <observation-file>

The panel prints percent REMAINING per window; this tool reports percent USED
(one decimal). "Refreshes in 153h 32m" becomes an absolute epoch computed from the
capture time; "Quota available" means a full window with no reset. Input that holds
no window yields status "unreadable", never 0%. No credential is read: the live
capture runs the CLI's own slash command and keeps neither stderr nor raw bytes beyond
the panel text. Observation files are written 0600, atomically.

`backend` (Issue #2465) asks Google's quota service for the same figures with the OAuth
access token `agy` keeps in the macOS login keychain (service "gemini", account
"antigravity"). The token lives in memory for the two requests only: it is never printed,
logged, saved or put in an error message, and the saved observation holds the service's
response (groups, buckets, fractions, reset times) and nothing else. Any failure is
reported as status "unreadable" with a fixed reason and error_class, never as a figure.

`terminal` (Issue #2466) runs interactive `agy` in a terminal a person can see, types `/usage`,
and saves the panel it prints with source "terminal". It never logs in: when `agy` shows a
sign-in prompt the person signs in at that terminal (keystrokes are forwarded to `agy`) and the
read finishes by itself. The terminal is the controlling terminal (/dev/tty), used only when
this process's own stdin is a terminal (AI_QUOTAS_TERMINAL_DEVICE names another device, for
tests). Nothing the session prints is logged or kept except a panel that parses.
"""
import base64
import datetime
import urllib.error
import urllib.parse
import urllib.request
import fcntl
import http.client
import json
import os
import re
import select
import subprocess
import sys
import tempfile
import time

SCHEMA = "antigravity-usage/1"
MAX_TEXT = 256 * 1024
FUTURE_SLACK = 300
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])")
BAR_CHARS = "█░▓▒▏▎▍▌▋▊▉▕■□▪▫"
PERCENT = re.compile(r"^(\d{1,3}(?:\.\d+)?)\s*%$")
STRAY_PERCENT = re.compile(r"^[^\s%]*\s*%$")
ACCOUNT = re.compile(r"^\s*Account:\s*(.+?)\s*$", re.I)
MODELS = re.compile(r"^\s*Models within this group:\s*(.+?)\s*$", re.I)
REFRESH = re.compile(r"^refreshes\s+in\b(.*)$", re.I)
DURATION = re.compile(r"^(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?$", re.I)
UNIT = (86400, 3600, 60, 1)


def clean_lines(text):
    text = ANSI.sub("", text).replace("\r", "\n")
    out = []
    for raw in text.split("\n"):
        line = "".join(ch for ch in raw if ch >= " " or ch == "\t")
        out.append(line.rstrip())
    return out


def strip_bars(line):
    return re.sub(r"[\[\]|]", "", "".join(" " if ch in BAR_CHARS else ch for ch in line)).strip()


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def short_group(name):
    s = slug(name)
    s = re.sub(r"(^|-)and(-|$)", "-", s)
    s = re.sub(r"-models?(?=-|$)", "", s)
    return re.sub(r"-+", "-", s).strip("-") or "group"


def window_name(title):
    t = title.lower()
    if re.search(r"\b(five|5)[ -]?hour", t):
        return "5-hour"
    if "weekly" in t:
        return "7-day"
    if "daily" in t:
        return "1-day"
    if "monthly" in t:
        return "30-day"
    t = re.sub(r"\b(remaining|limit)\b", " ", t)
    return slug(t) or "window"


def is_header(line):
    s = line.strip()
    if not s or ":" in s or "%" in s:
        return False
    letters = [c for c in s if c.isalpha()]
    return bool(letters) and all(c.isupper() for c in letters) and len(s) <= 80


def parse_reset(text, captured):
    """-> (resets_at_epoch|None, full, reset_text, malformed)"""
    stripped = text.strip()
    if re.fullmatch(r"quota available\.?", stripped, re.I):
        return None, True, stripped, False
    m = REFRESH.match(stripped)
    if m:
        d = DURATION.match(m.group(1).strip())
        if d and any(g is not None for g in d.groups()):
            seconds = sum(int(g) * u for g, u in zip(d.groups(), UNIT) if g is not None)
            return int(captured) + seconds, False, stripped, False
        return None, False, stripped, True
    return None, False, stripped, False


def parse_panel(text, captured):
    lines = clean_lines(text[:MAX_TEXT])
    account = None
    groups = []
    group = None
    out_of_range = False
    malformed = None
    entries = [(raw, strip_bars(raw)) for raw in lines]
    # Drop blank lines for lookahead but keep order.
    items = [(raw, s) for raw, s in entries if s]
    i = 0
    while i < len(items):
        raw, s = items[i]
        am = ACCOUNT.match(s)
        if am and account is None:
            account = am.group(1)
            i += 1
            continue
        if is_header(s):
            group = {"name": s.title() if s.isupper() else s, "raw_name": s, "slug": short_group(s), "models": [], "windows": []}
            groups.append(group)
            i += 1
            continue
        mm = MODELS.match(s)
        if mm and group is not None:
            group["models"] = [x.strip() for x in mm.group(1).split(",") if x.strip()]
            i += 1
            continue
        # A window title is any line directly followed by a percent line.
        if "%" not in s and i + 1 < len(items) and PERCENT.match(items[i + 1][1]):
            pct = float(PERCENT.match(items[i + 1][1]).group(1))
            reset_line = None
            if i + 2 < len(items) and (REFRESH.match(items[i + 2][1]) or re.fullmatch(r"quota available\.?", items[i + 2][1], re.I)):
                reset_line = items[i + 2][1]
            i += 3 if reset_line else 2
            if not 0.0 <= pct <= 100.0:
                out_of_range = True
                continue
            if group is None:
                group = {"name": "Unknown", "raw_name": "UNKNOWN", "slug": "unknown", "models": [], "windows": []}
                groups.append(group)
            resets, full, reset_text, bad_reset = parse_reset(reset_line or "", captured)
            if bad_reset:
                malformed = "a reset countdown is not in the d/h/m/s form; the panel is not trusted"
                continue
            group["windows"].append({
                "name": window_name(s),
                "title": s,
                "remaining_pct": round(pct, 1),
                "used_pct": round(100.0 - pct, 1),
                "resets_at_epoch": resets,
                "full": full,
                "reset_text": reset_text or None,
            })
            continue
        if STRAY_PERCENT.match(s):
            # A percent-looking line no window title claimed (negative, "N/A%", detached): not trusted.
            malformed = malformed or "a percent line was not recognised; the panel is not trusted"
        i += 1
    groups = [g for g in groups if g["windows"]]
    if malformed:
        return {"status": "unreadable", "reason": malformed, "account": account, "groups": []}
    if out_of_range:
        return {"status": "unreadable", "reason": "a percent outside 0-100 was printed; the panel is not trusted", "account": account, "groups": []}
    if not groups:
        return {"status": "unreadable", "reason": "no usage window found in the text", "account": account, "groups": []}
    return {"status": "ok", "account": account, "groups": groups}


# --- backend source (Issue #2465) ---------------------------------------------------------
DEFAULT_BASE = "https://daily-cloudcode-pa.googleapis.com/v1internal"
KEYCHAIN_PREFIX = "go-keyring-base64:"
LOAD_BODY = {"metadata": {"ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"}}
PROJECT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MAX_BODY = 1024 * 1024


class BackendError(Exception):
    def __init__(self, error_class, reason):
        Exception.__init__(self, reason)
        self.error_class = error_class
        self.reason = reason


def base_url():
    """The service root. Only a loopback override is honoured (tests), so the token can never
    be sent to a host chosen by the environment."""
    override = os.environ.get("AI_QUOTAS_ANTIGRAVITY_BACKEND_URL")
    if not override:
        return DEFAULT_BASE
    parsed = urllib.parse.urlparse(override)
    if parsed.scheme not in ("http", "https") or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise BackendError("backend_url", "AI_QUOTAS_ANTIGRAVITY_BACKEND_URL must point at a loopback address")
    return override.rstrip("/")


def read_stored_token():
    """-> (access_token, expiry_epoch|None). The value never leaves this process."""
    path = os.environ.get("AI_QUOTAS_ANTIGRAVITY_TOKEN_FILE")
    if path:
        try:
            raw = open(path).read().strip()
        except OSError:
            raise BackendError("token_missing", "no saved agy sign-in found")
    elif sys.platform == "darwin":
        try:
            proc = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise BackendError("token_missing", "the macOS keychain could not be read")
        if proc.returncode != 0:
            raise BackendError("token_missing", "agy has no saved sign-in in the keychain")
        raw = proc.stdout.decode("utf-8", "replace").strip()
    else:
        raise BackendError("token_unsupported", "reading the agy sign-in is only supported on macOS")
    try:
        if raw.startswith(KEYCHAIN_PREFIX):
            raw = raw[len(KEYCHAIN_PREFIX):]
            raw = base64.b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8")
        token = json.loads(raw)["token"]
        access = token["access_token"]
    except (ValueError, KeyError, TypeError, UnicodeDecodeError):
        raise BackendError("token_shape", "the saved agy sign-in has an unknown shape")
    if not isinstance(access, str) or not access or any(ord(ch) < 33 or ord(ch) > 126 for ch in access):
        raise BackendError("token_shape", "the saved agy sign-in has an unknown shape")
    expiry = None
    stamp = token.get("expiry")
    if isinstance(stamp, str):
        try:
            expiry = parse_rfc3339(stamp)
        except ValueError:
            expiry = None
    return access, expiry


def parse_rfc3339(text):
    m = re.fullmatch(r"(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?([Zz]|[+-]\d{2}:\d{2})", text.strip())
    if not m:
        raise ValueError("not RFC 3339")
    frac = (m.group(3) or "")[:6]
    zone = "+00:00" if m.group(4) in ("Z", "z") else m.group(4)
    stamp = "%sT%s%s%s" % (m.group(1), m.group(2), "." + frac if frac else "", zone)
    return int(datetime.datetime.fromisoformat(stamp).timestamp())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect: the Authorization header must never follow one to another host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirect)
# Loopback test overrides bypass environment proxies so the bearer token stays local.
LOOPBACK_OPENER = urllib.request.build_opener(NoRedirect, urllib.request.ProxyHandler({}))


def opener_for(url):
    host = urllib.parse.urlparse(url).hostname
    return LOOPBACK_OPENER if host in ("127.0.0.1", "localhost", "::1") else OPENER


def post_json(url, body, access):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Authorization": "Bearer " + access, "Content-Type": "application/json", "User-Agent": "antigravity-cli"})
    try:
        with opener_for(url).open(req, timeout=25) as resp:
            raw = resp.read(MAX_BODY + 1)
    except urllib.error.HTTPError as exc:
        code = exc.code
        if code == 401:
            raise BackendError("http_401", "Google rejected the saved agy sign-in (expired or signed out)")
        if code == 403:
            raise BackendError("http_403", "Google says this account has no Antigravity license")
        if code == 429:
            raise BackendError("http_429", "Google rate-limited the usage request")
        raise BackendError("http_%d" % code, "Google answered HTTP %d" % code)
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException):
        raise BackendError("network", "Google could not be reached")
    if len(raw) > MAX_BODY:
        raise BackendError("response_shape", "the usage response was too large")
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise BackendError("response_shape", "the usage response was not JSON")
    if not isinstance(doc, dict):
        raise BackendError("response_shape", "the usage response was not an object")
    return doc


def fetch_backend(now):
    access, expiry = read_stored_token()
    if expiry is not None and expiry <= int(now):
        raise BackendError("token_expired", "the saved agy sign-in has expired (agy renews it when it runs)")
    base = base_url()
    loaded = post_json(base + ":loadCodeAssist", LOAD_BODY, access)
    project = loaded.get("cloudaicompanionProject")
    if isinstance(project, dict):
        project = project.get("id")
    if not isinstance(project, str) or not PROJECT.match(project):
        raise BackendError("response_shape", "the account lookup named no usable project")
    summary = post_json(base + ":retrieveUserQuotaSummary", {"project": project}, access)
    result = parse_backend(summary, int(now))
    if result["status"] != "ok":
        raise BackendError("response_shape", result["reason"])
    return summary, result


def clean_text(text):
    return "".join(ch for ch in ANSI.sub("", text) if ch >= " ").strip()[:200]


def parse_backend(doc, captured):
    """Quota summary response -> the same result shape parse_panel returns. A bucket without
    a usable remainingFraction makes the whole reading unreadable: JSON omits zero, so an
    absent value cannot be told from an exhausted window and is never turned into a figure."""
    def bad(reason):
        return {"status": "unreadable", "reason": reason, "account": None, "groups": []}

    if not isinstance(doc, dict):
        return bad("the usage response was not an object")
    raw_groups = []
    listed = doc.get("groups")
    if listed is not None and not isinstance(listed, list):
        return bad("the usage groups have an unknown shape")
    for g in (listed or []):
        if not isinstance(g, dict) or not isinstance(g.get("buckets"), list):
            return bad("a usage group has an unknown shape")
        raw_groups.append((g.get("displayName"), g.get("description"), g["buckets"]))
    loose = doc.get("buckets")
    if isinstance(loose, list) and loose:
        raw_groups.append((None, None, loose))
    elif loose is not None and not isinstance(loose, list):
        return bad("the usage buckets have an unknown shape")
    groups = []
    for name, desc, buckets in raw_groups:
        name = clean_text(name) if isinstance(name, str) else ""
        if not name:
            name = "Unknown"
        models = []
        if isinstance(desc, str):
            mm = MODELS.match(clean_text(desc))
            if mm:
                models = [x.strip() for x in mm.group(1).split(",") if x.strip()]
        group = {"name": name, "raw_name": name, "slug": "unknown" if name == "Unknown" else short_group(name), "models": models, "windows": []}
        for b in buckets:
            if not isinstance(b, dict):
                return bad("a usage bucket has an unknown shape")
            if b.get("disabled") is True:
                continue
            frac = b.get("remainingFraction")
            if isinstance(frac, bool) or not isinstance(frac, (int, float)) or frac != frac:
                return bad("a usage bucket has no remainingFraction; the response is not trusted")
            if not 0 <= frac <= 1:
                return bad("a remainingFraction outside 0-1 was returned; the response is not trusted")
            title = clean_text(b.get("displayName")) if isinstance(b.get("displayName"), str) else ""
            wname = window_name(title) if title else ""
            if not wname or wname == "window":
                raw_window = b.get("window")
                wname = window_name(raw_window.replace("_", " ")) if isinstance(raw_window, str) and raw_window else "window"
            resets = None
            if b.get("resetTime") is not None:
                if not isinstance(b["resetTime"], str):
                    return bad("a reset time has an unknown shape")
                try:
                    resets = parse_rfc3339(b["resetTime"])
                except ValueError:
                    return bad("a reset time is not a date; the response is not trusted")
            remaining = round(float(frac) * 100.0, 1)
            group["windows"].append({
                "name": wname, "title": title or wname, "remaining_pct": remaining,
                "used_pct": round(100.0 - float(frac) * 100.0, 1), "resets_at_epoch": resets,
                "full": resets is None and remaining >= 100.0,
                "reset_text": b["resetTime"] if isinstance(b.get("resetTime"), str) else None,
            })
        if group["windows"]:
            groups.append(group)
    if not groups:
        return bad("no usage window found in the response")
    return {"status": "ok", "account": None, "groups": groups}


def read_text(path):
    data = sys.stdin.buffer.read(MAX_TEXT + 1) if path == "-" else open(path, "rb").read(MAX_TEXT + 1)
    return data.decode("utf-8", "replace")


class NewerKept(Exception):
    """A newer observation is already saved; the older capture is not written."""


def write_observation(path, captured, via, text, response=None, until=None):
    doc = {"schema": SCHEMA, "provider": "antigravity", "captured_at_epoch": int(captured), "via": via}
    if response is not None:
        doc["response"] = response
    else:
        doc["text"] = text[:MAX_TEXT]
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(folder, exist_ok=True)
    lock = os.open(os.path.join(folder, ".agy-obs.lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if until is None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        else:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= until:
                        raise TimeoutError("observation lock busy")
                    time.sleep(0.05)
        try:
            existing = json.load(open(path))
            kept = existing.get("captured_at_epoch") if isinstance(existing, dict) else None
        except (OSError, ValueError):
            kept = None
        if isinstance(kept, int) and not isinstance(kept, bool) and kept > int(captured):
            raise NewerKept()
        fd, tmp = tempfile.mkstemp(prefix=".agy-obs.", dir=folder)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(doc, handle)
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    finally:
        os.close(lock)

# --- terminal source (Issue #2466) --------------------------------------------------------
# A sign-in prompt, deliberately narrow: a ready screen that merely lists a /login hint must
# not be mistaken for a signed-out one, and nothing here ever answers such a prompt.
SIGNIN = re.compile(
    r"(?:please|must|need\s+to)\s+(?:sign|log)[\s-]*in|not\s+(?:signed|logged)[\s-]*in"
    r"|(?:sign|log)[\s-]*in\s+(?:required|to\s+continue|with\s+google)|authenticat\w*\s+(?:required|needed|to\s+continue)"
    r"|accounts\.google\.com|oauth",
    re.I)
RAW_CAP = 512 * 1024
HUMAN_QUIET = 5.0


CLEAR_SCREEN = (b"\x1b[2J", b"\x1b[3J", b"\x1bc")


def current_screen_text(raw, burst):
    """Text of the latest burst of output, cut at the last clear-screen sequence: whatever the
    program painted before clearing is history, not the prompt on screen now."""
    chunk = raw[burst:]
    cut = max(chunk.rfind(seq) + len(seq) if chunk.rfind(seq) >= 0 else 0 for seq in CLEAR_SCREEN)
    return "\n".join(clean_lines(chunk[cut:].decode("utf-8", "replace")))


class TerminalError(Exception):
    def __init__(self, error_class, reason):
        Exception.__init__(self, reason)
        self.error_class = error_class
        self.reason = reason


def tty_write(fd, data, until):
    """Write all of data to a non-blocking descriptor, never past the monotonic time `until`
    (a stalled child or terminal raises TimeoutError instead of hanging the capture)."""
    while data:
        try:
            n = os.write(fd, data)
            data = data[n:]
        except InterruptedError:
            continue
        except BlockingIOError:
            left = until - time.monotonic()
            if left <= 0:
                raise TimeoutError("write stalled")
            select.select([], [fd], [], min(left, 0.5))


def run_terminal(agy, started, obs):
    import fcntl as _fcntl
    import pty
    import signal
    import termios
    import tty

    override = os.environ.get("AI_QUOTAS_TERMINAL_DEVICE")
    if not override and not sys.stdin.isatty():
        raise TerminalError("terminal_unavailable", "no visible terminal here (this shell has no terminal on its input)")
    try:
        tfd = os.open(override or "/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        raise TerminalError("terminal_unavailable", "no visible terminal here (the controlling terminal cannot be opened)")
    if not os.isatty(tfd):
        os.close(tfd)
        raise TerminalError("terminal_unavailable", "no visible terminal here (not a terminal)")
    try:
        limit = int(os.environ.get("AI_QUOTAS_TERMINAL_TIMEOUT", "300"))
    except ValueError:
        limit = 300
    limit = min(max(limit, 5), 1800)
    agy = os.path.abspath(agy)
    if not os.path.isfile(agy) or not os.access(agy, os.X_OK):
        os.close(tfd)
        raise TerminalError("agy_missing", "the agy CLI was not found")

    saved_attrs = termios.tcgetattr(tfd)
    resized = []
    old_winch = signal.signal(signal.SIGWINCH, lambda *_: resized.append(1))

    def stop_requested(signum, _frame):
        raise SystemExit(128 + signum)   # unwinds through the cleanup below, which restores the terminal

    old_term = signal.signal(signal.SIGTERM, stop_requested)
    old_hup = signal.signal(signal.SIGHUP, stop_requested)
    mono0 = time.monotonic()
    capture_deadline = mono0 + limit
    pid = -1
    master = -1
    try:
        pid, master = pty.fork()
        if pid == 0:
            try:
                os.chdir(os.path.expanduser("~"))
                os.environ.setdefault("TERM", "xterm-256color")
                os.execv(agy, [agy])
            finally:
                os._exit(127)

        def sync_size():
            try:
                _fcntl.ioctl(master, termios.TIOCSWINSZ, _fcntl.ioctl(tfd, termios.TIOCGWINSZ, b"\0" * 8))
            except OSError:
                pass

        sync_size()
        os.set_blocking(master, False)
        os.set_blocking(tfd, False)
        tty.setraw(tfd)
        tty_write(tfd, b"\r\n[quotas] reading Antigravity usage in this terminal: agy starts, /usage is typed for you. "
                       b"If agy asks you to sign in, do it here; the read finishes by itself. "
                       b"Giving up after %ds.\r\n" % limit, capture_deadline)
        raw = b""
        mark = 0
        burst = 0
        human_at = -1e9
        last_out = last_data = time.monotonic()
        last_send = -1e9
        sends = 0
        signin_noted = False
        signin_seen = False
        child_gone = False
        panel = None
        deadline = mono0 + limit
        while time.monotonic() < deadline:
            if resized:
                del resized[:]
                sync_size()
            try:
                ready, _, _ = select.select([tfd, master], [], [], 0.2)
            except InterruptedError:
                continue
            now = time.monotonic()
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except BlockingIOError:
                    data = None
                except OSError:
                    data = b""
                if data is not None and not data:
                    child_gone = True
                    break
            if master in ready and data is not None:
                tty_write(tfd, data, capture_deadline)
                # Screen state survives output pauses: a sign-in prompt followed by a spinner stays
                # on screen. Only a clear-screen sequence (handled in current_screen_text) ends it.
                raw += data
                if len(raw) > RAW_CAP:
                    drop = len(raw) - RAW_CAP
                    raw = raw[drop:]
                    mark = max(0, mark - drop)
                    burst = max(0, burst - drop)
                last_out = last_data = now
            if tfd in ready:
                try:
                    keys = os.read(tfd, 4096)
                except OSError:
                    keys = b""
                if keys:
                    tty_write(master, keys, capture_deadline)
                    human_at = now
                    last_out = now
            quiet = now - last_out
            if sends and quiet >= 1.5:
                seg = raw[mark:].decode("utf-8", "replace")
                at = int(started) + int(now - mono0)
                parsed = parse_panel(seg, at)
                if parsed["status"] == "ok":
                    # A repaint that left two frames in the stream would repeat windows: refuse it.
                    keys_seen = [(g["slug"], w["name"]) for g in parsed["groups"] for w in g["windows"]]
                    if len(keys_seen) != len(set(keys_seen)):
                        raise TerminalError("panel_garbled", "agy repainted the panel and the captured text repeats windows")
                    panel = (parsed, at, "\n".join(clean_lines(seg)))
                    break
            if raw and quiet >= 2.5 and sends < 4 and now - last_send >= 20:
                # Signed out = the latest burst of output still asks for a sign-in; the person also
                # gets a few quiet seconds after typing before /usage is sent (never mid-login).
                latest = current_screen_text(raw, burst)
                if SIGNIN.search(latest) or (signin_seen and now - human_at < HUMAN_QUIET):
                    signin_seen = True
                    if not signin_noted:
                        signin_noted = True
                        tty_write(tfd, b"\r\n[quotas] sign in to Antigravity in this terminal, then wait: the read finishes by itself. "
                                       b"Nothing here signs in for you.\r\n", capture_deadline)
                else:
                    mark = len(raw)
                    signin_seen = False   # the sign-in, if any, is over: a later failure is not a sign-in timeout
                    sends += 1
                    last_send = now
                    tty_write(master, b"/usage", capture_deadline)
                    time.sleep(0.5)
                    tty_write(master, b"\r", capture_deadline)
        if panel is None:
            if child_gone:
                try:
                    _, status = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    status = 0
                code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
                raise TerminalError("agy_exited", "agy exited before showing usage (exit %d)" % code)
            if signin_seen:
                raise TerminalError("signin_timeout", "no sign-in to Antigravity within %ds" % limit)
            raise TerminalError("terminal_timeout", "agy showed no usage panel within %ds" % limit)
        parsed, at, text = panel
        write_observation(obs, at, "terminal", text, until=capture_deadline)
        parsed["captured_at_epoch"] = at
        return parsed
    except TimeoutError:
        raise TerminalError("terminal_timeout", "the terminal or agy stopped accepting input")
    finally:
        signal.signal(signal.SIGWINCH, old_winch)
        signal.signal(signal.SIGTERM, old_term)
        signal.signal(signal.SIGHUP, old_hup)
        if pid > 0:
            try:
                tty_write(master, b"\x03", time.monotonic() + 0.5)
                time.sleep(0.3)
                tty_write(master, b"\x03", time.monotonic() + 0.5)
            except (OSError, TimeoutError):
                pass
            end = time.monotonic() + 1.5
            reaped = False
            while time.monotonic() < end and not reaped:
                try:
                    done, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    reaped = True
                    break
                if done:
                    reaped = True
                else:
                    time.sleep(0.1)
            if not reaped:
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.kill(pid, sig)
                        time.sleep(0.3)
                        done, _ = os.waitpid(pid, os.WNOHANG)
                        if done:
                            break
                    except (OSError, ChildProcessError):
                        break
        if master >= 0:
            try:
                os.close(master)
            except OSError:
                pass
        try:
            termios.tcsetattr(tfd, termios.TCSANOW, saved_attrs)
            tty_write(tfd, b"\r\n", time.monotonic() + 0.5)
        except (OSError, TimeoutError, termios.error):
            pass
        os.close(tfd)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    try:
        if cmd == "parse" and len(argv) == 4:
            print(json.dumps(parse_panel(read_text(argv[2]), int(argv[3]))))
            return 0
        if cmd == "ingest" and len(argv) == 6:
            text = read_text(argv[2])
            result = parse_panel(text, int(argv[3]))
            if result["status"] != "ok":
                print(json.dumps(result))
                return 3
            write_observation(argv[5], int(argv[3]), argv[4], text)
            print(json.dumps(result))
            return 0
        if cmd == "show" and len(argv) == 4:
            try:
                doc = json.load(open(argv[2]))
            except FileNotFoundError:
                print(json.dumps({"status": "missing"}))
                return 0
            except (OSError, ValueError):
                print(json.dumps({"status": "unreadable", "reason": "observation file is not valid JSON"}))
                return 0
            if not isinstance(doc, dict) or doc.get("schema") != SCHEMA \
                    or not (isinstance(doc.get("text"), str) or isinstance(doc.get("response"), dict)) \
                    or not isinstance(doc.get("captured_at_epoch"), int) or isinstance(doc.get("captured_at_epoch"), bool):
                print(json.dumps({"status": "unreadable", "reason": "observation file has an unknown shape"}))
                return 0
            captured = doc["captured_at_epoch"]
            if captured > int(argv[3]) + FUTURE_SLACK:
                print(json.dumps({"status": "unreadable", "reason": "the saved capture time is in the future"}))
                return 0
            if isinstance(doc.get("response"), dict) and doc.get("via") == "backend":
                result = parse_backend(doc["response"], captured)
            elif isinstance(doc.get("text"), str):
                result = parse_panel(doc["text"], captured)
            else:
                result = {"status": "unreadable", "reason": "observation file has an unknown shape", "account": None, "groups": []}
            result.update(captured_at_epoch=captured, age_seconds=max(0, int(argv[3]) - captured),
                          via=doc.get("via") if isinstance(doc.get("via"), str) else "unknown")
            print(json.dumps(result))
            return 0
        if cmd == "parse-backend" and len(argv) == 4:
            try:
                parsed = json.loads(read_text(argv[2]))
            except ValueError:
                print(json.dumps({"status": "unreadable", "reason": "the usage response was not JSON"}))
                return 3
            print(json.dumps(parse_backend(parsed, int(argv[3]))))
            return 0
        if cmd == "backend" and len(argv) == 4:
            captured = int(argv[2])
            try:
                summary, result = fetch_backend(captured)
            except BackendError as exc:
                print(json.dumps({"status": "unreadable", "reason": exc.reason, "error_class": exc.error_class}))
                return 3
            write_observation(argv[3], captured, "backend", None, response=summary)
            print(json.dumps(result))
            return 0
        if cmd == "terminal" and len(argv) == 5:
            try:
                result = run_terminal(argv[2], int(argv[3]), argv[4])
            except TerminalError as exc:
                print(json.dumps({"status": "unreadable", "reason": exc.reason, "error_class": exc.error_class}))
                return 3
            print(json.dumps(result))
            return 0
        if cmd == "capture" and len(argv) == 5:
            try:
                proc = subprocess.run([argv[2], "-p", "/usage"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL, timeout=90, check=False)
            except subprocess.TimeoutExpired:
                print(json.dumps({"status": "unreadable", "reason": "agy did not answer within 90s"}))
                return 3
            except OSError:
                print(json.dumps({"status": "unreadable", "reason": "agy could not be started"}))
                return 3
            text = proc.stdout[:MAX_TEXT].decode("utf-8", "replace")
            result = parse_panel(text, int(argv[3]))
            if result["status"] != "ok":
                result["reason"] = "agy -p /usage printed no usage panel (exit %d); use the manual route" % proc.returncode
                print(json.dumps(result))
                return 3
            write_observation(argv[4], int(argv[3]), "agy-print", text)
            print(json.dumps(result))
            return 0
    except NewerKept:
        print(json.dumps({"status": "unreadable", "reason": "a newer reading is already saved; this older capture was not written"}))
        return 3
    except (ValueError, OSError) as exc:
        print(json.dumps({"status": "unreadable", "reason": "%s" % type(exc).__name__}))
        return 3
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
