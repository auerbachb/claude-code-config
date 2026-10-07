"""desk/hooks/capture.py — the capture hook's logic (issue #1755).

Run by capture.sh (registered as .claude/hooks/human-queue-capture.sh, a
PreToolUse hook with matcher AskUserQuestion). desk/README.md, "Capture hook",
is the contract; this docstring is the summary.

  stdin   the hook input: {"session_id", "cwd", "tool_name",
          "tool_input": {"questions": [{"question", "header", "options":
          [{"label", "description"}], "multiSelect"}]}, ...}
  stdout  nothing (the menu renders), or one JSON object that denies the call
          with a reason (the shape worktree-guard.sh uses)
  stderr  at most one line, prefixed "human-queue-capture: ", and only when
          the hook could not do its job
  exit    0, always: the hook never blocks a thread because of its own failure

Flow:
  1. Find the store's URL (environment, then an owner-only config file, then
     a literal export line in a shell profile) and run
     `human-queue.sh control-status --json`.
  2. No live desk (no control session, or its last tick is older than the
     bound): allow. Nothing is queued.
  3. Live desk: one `human-queue.sh add --kind decision` per question, with
     the asking session as the return address. The desk's own session is
     allowed; any other session is denied with the receipt instruction.

Every failure (no URL, no CLI, a non-zero CLI exit, a timeout, malformed
input, an internal error) allows the menu with one warning line. Neither the
URL nor raw CLI output nor exception text is ever printed.

Python 3.9 compatible (macOS /usr/bin/python3).
"""

import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time
import unicodedata

PREFIX = "human-queue-capture: "
TAIL = "; the menu renders in this thread"

# The live-desk bound: a control session whose last tick is at most this many
# minutes old is a live desk. desk/policy.json may override it with
# live_desk_max_tick_age_min (1 to 1440). 15 minutes is three missed ticks at
# the desk's default five-minute cadence (issue #1779).
DEFAULT_LIVE_MINUTES = 15
POLICY_KEY = "live_desk_max_tick_age_min"

# Time bounds. The registered hook timeout is 15 s (global-settings.json); the
# hook gives up at 12 s so it can still say why. A CLI call that cannot reach
# the store exits 7 within two seconds by contract; 6 s also covers the SQL.
TOTAL_BUDGET_S = 12.0
CALL_TIMEOUT_S = 6.0
GIT_TIMEOUT_S = 2.0

# Store limits (desk/README.md, Items). Capped in UTF-8 bytes, so they hold
# whether the CLI counts characters or, in the C locale, bytes.
MAX_QUESTION = 500
MAX_OPTION = 500
MAX_OPTIONS = 26
MAX_CONTEXT_TOTAL = 600
MAX_KEY = 200

PROFILES = (".zprofile", ".zshenv", ".zshrc", ".bash_profile", ".bashrc", ".profile")
CONFIG_FILE = os.path.join("human-queue", "database_url")

ID_RE = re.compile(r"^D-[1-9][0-9]*$")
REPO_RE = re.compile(r"^[^/\s]+/[^/\s]+$")
ASSIGN_RE = re.compile(r"^\s*(?:export\s+)?HUMAN_QUEUE_DATABASE_URL=(.*)$")
# The three literal forms of an assignment's value, each optionally followed
# by `;` and a comment. Anything else (an expansion, a substitution, a
# backslash escape, a pipeline) is refused, never evaluated.
LITERAL_RES = (
    re.compile(r"^'([^']*)'\s*;?\s*(?:#.*)?$"),
    re.compile(r'^"([^"$`\\]*)"\s*;?\s*(?:#.*)?$'),
    re.compile(r"^([^\s'\"`$\\;&|<>(){}]+)\s*;?\s*(?:#.*)?$"),
)

HOOK_DIR = os.path.dirname(os.path.realpath(__file__))
DESK_DIR = os.path.dirname(HOOK_DIR)


class FailOpen(Exception):
    """A one-line, secret-free reason the hook could not do its job."""


class Hook(object):
    def __init__(self, started):
        self.deadline = started + TOTAL_BUDGET_S
        # A problem that does not stop the hook (an ignored config file, a bad
        # policy value). Printed only when nothing else is, so stderr never
        # carries more than one line.
        self.note = ""

    def remember(self, note):
        if not self.note:
            self.note = note


# --- text shaping ------------------------------------------------------------

def cap_bytes(text, limit):
    """TEXT cut to at most LIMIT UTF-8 bytes, marked with an ellipsis."""
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    cut = raw[: limit - 3].decode("utf-8", "ignore").rstrip()
    return cut + "…"


def one_line(value, limit):
    """VALUE as one line the store accepts: runs of whitespace become one
    space, other control characters are dropped, at most LIMIT bytes."""
    if not isinstance(value, str):
        return ""
    kept = "".join(ch for ch in value if ch.isspace() or unicodedata.category(ch) != "Cc")
    return cap_bytes(" ".join(kept.split()), limit)


def item_key(value):
    """VALUE as a --key of at most MAX_KEY bytes. A longer one keeps its start
    and ends in a short hash of the whole value, so two long branch names that
    share a prefix stay two keys (a plain cut would make them one, and add's
    dedupe would merge their questions into one item)."""
    whole = one_line(value, 1 << 30)
    raw = whole.encode("utf-8")
    if len(raw) <= MAX_KEY:
        return whole
    digest = hashlib.sha256(raw).hexdigest()[:12]
    return cap_bytes(whole, MAX_KEY - len(digest) - 1) + "~" + digest


def is_recommended(label):
    return label.lower().endswith("(recommended)")


class Question(object):
    def __init__(self, text, options, default, context):
        self.text = text
        self.options = options
        self.default = default
        self.context = context


def shape_question(raw, n):
    if not isinstance(raw, dict):
        raise FailOpen("question %d is not an object" % n)
    text = one_line(raw.get("question"), MAX_QUESTION)
    if not text:
        raise FailOpen("question %d has no text" % n)

    options = []
    descriptions = []
    raw_options = raw.get("options")
    if not isinstance(raw_options, list):
        raw_options = []
    for opt in raw_options:
        if isinstance(opt, dict):
            label = one_line(opt.get("label"), MAX_OPTION)
            desc = one_line(opt.get("description"), MAX_CONTEXT_TOTAL)
        else:
            label = one_line(opt, MAX_OPTION)
            desc = ""
        # The store answers options by letter, so they must be distinct.
        if not label or label in options or len(options) >= MAX_OPTIONS:
            continue
        options.append(label)
        if desc:
            descriptions.append("%s: %s" % (label, desc))

    default = None
    for label in options:
        if is_recommended(label):
            default = label
            break
    if default is None and options:
        # ask-menu.md puts the recommended option first.
        default = options[0]

    context = []
    header = one_line(raw.get("header"), 100)
    if header:
        context.append("Header: " + header)
    if raw.get("multiSelect") is True:
        context.append("More than one option may be chosen.")
    if descriptions:
        used = sum(len(c.encode("utf-8")) for c in context)
        room = MAX_CONTEXT_TOTAL - used
        if room >= 40:
            context.append(cap_bytes("Options: " + "; ".join(descriptions), room))
    return Question(text, options, default, context)


# --- the store's URL (AC 4.3a) -----------------------------------------------

def literal_value(rhs):
    """The value of a shell assignment's right-hand side when it is a plain
    literal, else None. Nothing is ever expanded or run."""
    rhs = rhs.strip()
    for pattern in LITERAL_RES:
        m = pattern.match(rhs)
        if m:
            return m.group(1)
    return None


def url_from_config(hook):
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    path = os.path.join(base, CONFIG_FILE)
    try:
        st = os.stat(path)
    except OSError:
        return None
    shown = path.replace(os.path.expanduser("~"), "~", 1)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        hook.remember("%s is ignored: it must be a file you own with mode 600" % shown)
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read(65536).splitlines()
    except OSError:
        hook.remember("%s is not readable" % shown)
        return None
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    return None


def url_from_profiles(hook):
    home = os.path.expanduser("~")
    for name in PROFILES:
        path = os.path.join(home, name)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read(1048576)
        except OSError:
            continue
        last = None
        for line in text.splitlines():
            m = ASSIGN_RE.match(line)
            if m:
                last = m.group(1)
        if last is None:
            continue
        # The shell keeps the last assignment, so only that one counts.
        value = literal_value(last)
        if value:
            return value
        hook.remember("~/%s sets HUMAN_QUEUE_DATABASE_URL to something other than a literal; it is not run" % name)
        return None
    return None


def resolve_url(hook):
    value = os.environ.get("HUMAN_QUEUE_DATABASE_URL", "")
    if value.strip():
        return value
    value = url_from_config(hook) or url_from_profiles(hook)
    if value:
        return value
    if hook.note:
        raise FailOpen(hook.note)
    raise FailOpen("HUMAN_QUEUE_DATABASE_URL is not in the environment, "
                   "~/.config/human-queue/database_url, or a shell profile")


# --- running things ----------------------------------------------------------

def run_bounded(hook, argv, env, cap, what):
    """(status, stdout, first stderr line) of ARGV, killed with its whole
    process group past CAP seconds or the hook's deadline."""
    remaining = hook.deadline - time.monotonic()
    if remaining < 0.5:
        raise FailOpen("ran out of time before %s" % what)
    timeout = min(cap, remaining)
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, start_new_session=True)
    except OSError:
        raise FailOpen("could not start %s" % what)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        raise FailOpen("%s took longer than %.0f s" % (what, timeout))
    err_lines = [ln.strip() for ln in err.decode("utf-8", "replace").splitlines() if ln.strip()]
    first = one_line(err_lines[0], 200) if err_lines else ""
    return proc.returncode, out.decode("utf-8", "replace"), first


def bash_path():
    for candidate in os.environ.get("PATH", "").split(os.pathsep) + ["/bin", "/usr/bin"]:
        path = os.path.join(candidate or ".", "bash")
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise FailOpen("bash is not installed")


class Store(object):
    def __init__(self, hook, cli, env):
        self.hook = hook
        self.argv = [bash_path(), cli]
        self.env = env

    def call(self, args, what):
        rc, out, err = run_bounded(self.hook, self.argv + args, self.env, CALL_TIMEOUT_S, what)
        if rc == 0:
            return out
        if rc == 7:
            reason = "the store is unreachable"
        elif rc == 5:
            reason = "it looks like it holds a secret, so it was not stored"
        elif rc == 4:
            reason = "the CLI refused it"
        else:
            reason = "the CLI failed"
        detail = (": " + err) if err else ""
        raise FailOpen("%s: %s (human-queue.sh exit %d%s)" % (what, reason, rc, detail))


def resolve_cli():
    cli = os.environ.get("HUMAN_QUEUE_CLI") or os.path.join(DESK_DIR, "bin", "human-queue.sh")
    if not os.path.isfile(cli):
        raise FailOpen("human-queue.sh not found at %s" % cli)
    return cli


def policy_minutes(hook):
    path = os.environ.get("HUMAN_QUEUE_POLICY") or os.path.join(DESK_DIR, "policy.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return DEFAULT_LIVE_MINUTES
    except (OSError, ValueError):
        hook.remember("%s is unreadable or not valid JSON; using the %d-minute live-desk bound"
                      % (os.path.basename(path), DEFAULT_LIVE_MINUTES))
        return DEFAULT_LIVE_MINUTES
    if not isinstance(data, dict) or POLICY_KEY not in data:
        return DEFAULT_LIVE_MINUTES
    value = data[POLICY_KEY]
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 1440:
        hook.remember("%s: %s must be a whole number of minutes from 1 to 1440; using %d"
                      % (os.path.basename(path), POLICY_KEY, DEFAULT_LIVE_MINUTES))
        return DEFAULT_LIVE_MINUTES
    return value


def live_control_session(hook, store):
    """The registered control session when the desk is live, else None."""
    out = store.call(["control-status", "--json"], "control-status")
    try:
        status = json.loads(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise FailOpen("control-status printed something other than JSON")
    if not isinstance(status, dict):
        raise FailOpen("control-status printed something other than a JSON object")
    session = status.get("session")
    age = status.get("tick_age_seconds")
    if not isinstance(session, str) or not session:
        return None
    if isinstance(age, bool) or not isinstance(age, int):
        return None
    if age > policy_minutes(hook) * 60:
        return None
    return session


def git_env():
    """The hook's environment without the store's URL: only human-queue.sh
    needs the credential, so no other child inherits it, even when the
    asking session exported it (the store's lib/db.sh drops it the same way)."""
    env = dict(os.environ)
    env.pop("HUMAN_QUEUE_DATABASE_URL", None)
    return env


def git_out(hook, cwd, args):
    try:
        rc, out, _ = run_bounded(hook, ["git", "-C", cwd] + args, git_env(), GIT_TIMEOUT_S, "git")
    except FailOpen:
        return ""
    return out.strip() if rc == 0 else ""


def repo_and_key(hook, cwd, session):
    """--repo and --key for the asking thread. The key is what the question
    belongs to: the issue its branch names, else the branch, else (on main or
    a detached HEAD) the session, so unrelated threads never share an item."""
    if not isinstance(cwd, str) or not os.path.isdir(cwd):
        cwd = os.getcwd()
    repo = ""
    origin = git_out(hook, cwd, ["remote", "get-url", "origin"])
    m = re.search(r"[:/]([^/:\s]+)/([^/\s]+?)(?:\.git)?/?$", origin)
    if m:
        repo = "%s/%s" % (m.group(1), m.group(2))
    if not REPO_RE.match(repo) or len(repo) > 200:
        top = git_out(hook, cwd, ["rev-parse", "--show-toplevel"]) or cwd
        name = re.sub(r"[\s/]+", "-", os.path.basename(top.rstrip("/"))) or "unknown"
        repo = cap_bytes("local/" + name, 200)

    branch = git_out(hook, cwd, ["branch", "--show-current"])
    m = re.match(r"^issue-([0-9]+)(?:-|$)", branch)
    if m:
        key = "issue-" + m.group(1)
    elif branch and branch not in ("main", "master"):
        key = item_key("branch:" + branch)
    else:
        key = item_key("session:" + session)
    return repo, key


def add_question(store, n, repo, key, session, q):
    args = ["add", "--kind", "decision", "--repo", repo, "--key", key,
            "--question", q.text, "--session", session]
    for line in q.context:
        args += ["--context", line]
    for label in q.options:
        args += ["--option", label]
    if q.default:
        args += ["--default", q.default]
    out = store.call(args, "question %d" % n)
    item = out.strip()
    if not ID_RE.match(item):
        raise FailOpen("question %d: add printed no item id" % n)
    return item


def deny(ids):
    if len(ids) == 1:
        reason = ("Queued as {0}. Print exactly: question {0} sent to human queue. "
                  "Then proceed on your recommended default or park and wait for a wake-up.").format(ids[0])
    else:
        joined = ", ".join(ids)
        reason = ("Queued as {0}. Print exactly: questions {0} sent to human queue. "
                  "Then proceed on your recommended defaults or park and wait for a wake-up.").format(joined)
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def run(hook, raw):
    try:
        data = json.loads(raw)
    except ValueError:
        raise FailOpen("the hook input is not JSON")
    if not isinstance(data, dict):
        raise FailOpen("the hook input is not a JSON object")
    # Defense in depth: the matcher is AskUserQuestion, but a widened matcher
    # or a direct run must never queue anything else.
    if data.get("tool_name") != "AskUserQuestion":
        return None
    session = data.get("session_id")
    if not isinstance(session, str) or not session.strip():
        raise FailOpen("the hook input has no session_id")
    tool_input = data.get("tool_input")
    raw_questions = tool_input.get("questions") if isinstance(tool_input, dict) else None
    if not isinstance(raw_questions, list) or not raw_questions:
        raise FailOpen("the hook input has no questions")

    cli = resolve_cli()
    env = dict(os.environ)
    env["HUMAN_QUEUE_DATABASE_URL"] = resolve_url(hook)
    store = Store(hook, cli, env)

    control = live_control_session(hook, store)
    if control is None:
        return None

    questions = [shape_question(q, n) for n, q in enumerate(raw_questions, 1)]
    repo, key = repo_and_key(hook, data.get("cwd"), session)
    ids = []
    for n, q in enumerate(questions, 1):
        try:
            item = add_question(store, n, repo, key, session, q)
        except FailOpen as exc:
            if ids:
                raise FailOpen("%s (already queued: %s)" % (exc, ", ".join(ids)))
            raise
        if item not in ids:
            ids.append(item)

    if session == control:
        # The desk's own session: its menu renders, and the item exists.
        return None
    return deny(ids)


def warn(message):
    line = " ".join(str(message).split())
    sys.stderr.write(PREFIX + line + TAIL + "\n")


def main():
    hook = Hook(time.monotonic())
    try:
        raw = sys.stdin.read()
        decision = run(hook, raw)
    except FailOpen as exc:
        warn(exc)
        return 0
    except Exception as exc:  # the hook must never block on its own bug
        warn("internal error (%s)" % type(exc).__name__)
        return 0
    if decision is not None:
        sys.stdout.write(json.dumps(decision) + "\n")
    if hook.note:
        sys.stderr.write(PREFIX + " ".join(hook.note.split()) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
