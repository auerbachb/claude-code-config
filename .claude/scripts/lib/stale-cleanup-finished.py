"""Finished-only worktree detection/apply. No age, prune, checkout or remote deletion."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import uuid


class Unknown(Exception):
    pass


class Skip(Exception):
    pass


def bound(name, default):
    try:
        value = float(os.environ.get(name, default))
        return min(value, 300) if math.isfinite(value) and value > 0 else default
    except ValueError:
        return default


GIT_TIMEOUT = bound("STALE_CLEANUP_TIMEOUT_SECS", 10)
GH_TIMEOUT = bound("STALE_CLEANUP_GH_TIMEOUT_SECS", 60)
LSOF_TIMEOUT = bound("STALE_CLEANUP_LSOF_TIMEOUT_SECS", 10)
REMOVE_TIMEOUT = bound("STALE_CLEANUP_REMOVE_TIMEOUT_SECS", 120)
MAX_OUTPUT = 2 * 1024 * 1024

REF_TRANSACTION_GUARD = r"""
import os, stat, subprocess, sys
from pathlib import Path
prefix = 'CLAUDE_FINISHED_REF_GUARD_'
stage = sys.argv[1] if len(sys.argv) == 2 else ''
if stage not in ('preparing', 'prepared', 'committed', 'aborted'):
    sys.exit(1)
payload = sys.stdin.buffer.read(2 * 1024 * 1024 + 1)
if len(payload) > 2 * 1024 * 1024:
    sys.exit(1)
expected = os.environ[prefix + 'SHA'].encode()
target = os.environ[prefix + 'REF'].encode()
anchor = os.environ[prefix + 'ANCHOR'].encode()
zero = b'0' * len(expected)
# Forward the repository's actual hook, restoring the pre-command config.
# Our transient hooksPath and pinned-upstream overrides must not change what
# that hook (or its own Git children) sees. No persistent config is edited.
env = dict(os.environ)
if env[prefix + 'CONFIG_PRESENT'] == '1':
    env['GIT_CONFIG_PARAMETERS'] = env[prefix + 'CONFIG']
else:
    env.pop('GIT_CONFIG_PARAMETERS', None)
for key in list(env):
    if key.startswith(prefix):
        env.pop(key)
if stage == 'prepared':
    for line in payload.splitlines():
        parts = line.split()
        if len(parts) != 3:
            sys.exit(1)
        old, new, ref = parts
        if ref == target:
            # branch -d supplies no old OID, so Git reports zero here. Read
            # the real tip while this prepared transaction holds its lock.
            # A cooperating writer cannot advance it before this commit.
            current = subprocess.run(['git', 'rev-parse', '--verify',
                                      target.decode('utf-8')], env=env,
                                     stdout=subprocess.PIPE)
            if (current.returncode or current.stdout.strip() != expected
                    or old not in (zero, expected) or new != zero):
                sys.exit(1)
        if ref == anchor:
            if old == zero and new == expected:
                Path(os.environ[prefix + 'MARKER']).write_text('prepared\n')
            elif old != expected or new != zero:
                sys.exit(1)
resolved = subprocess.run(['git', 'rev-parse', '--path-format=absolute',
                           '--git-path', 'hooks/reference-transaction'],
                          env=env, stdout=subprocess.PIPE)
if resolved.returncode:
    sys.exit(1)
hook = resolved.stdout.decode('utf-8').rstrip('\n')
if not os.path.isabs(hook):
    sys.exit(1)
try:
    info = os.stat(hook)
except (FileNotFoundError, NotADirectoryError):
    sys.exit(0)
if not stat.S_ISREG(info.st_mode):
    sys.exit(1)
if not os.access(hook, os.X_OK):
    sys.exit(0)
sys.exit(subprocess.run([hook, stage], input=payload, env=env).returncode)
"""


def run(args, cwd, timeout=GIT_TIMEOUT, env=None):
    """Bound process groups and capture files, not unbounded pipes in memory."""
    try:
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            proc = subprocess.Popen(args, cwd=cwd, env=env, stdout=out, stderr=err,
                                    start_new_session=True)
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=2)
                except ProcessLookupError:
                    pass
                raise Unknown("probe_timeout")
            except BaseException:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=2)
                except ProcessLookupError:
                    pass
                raise
            for stream in (out, err):
                if stream.tell() > MAX_OUTPUT:
                    raise Unknown("probe_output_limit")
                stream.seek(0)
            return proc.returncode, out.read().decode("utf-8"), err.read().decode("utf-8")
    except (OSError, UnicodeError, subprocess.SubprocessError) as exc:
        raise Unknown("probe_unavailable: " + str(exc)) from exc


def checked(args, cwd, timeout=GIT_TIMEOUT, env=None):
    code, out, _ = run(args, cwd, timeout, env)
    if code:
        raise Unknown("probe_failed: " + args[0])
    return out


def canonical(path, cwd):
    value = checked(["bash", "-c", 'cd -- "$1" && pwd -P', "finished-canonical", path], cwd)
    result = value.rstrip("\n")
    if not result.startswith("/") or "\n" in result:
        raise Unknown("canonical_path_unknown")
    return result


class Sweep:
    def __init__(self, root, caller, pr_unavailable=False, only=None):
        self.root = root
        # None = every worktree (the repo-wide default). A list restricts the
        # scan to exactly those worktree paths; it can only narrow, never widen.
        self.only = only
        self.caller = caller
        self.pr_unavailable = pr_unavailable
        self.cwds = None
        self.repo = None
        self.host = None
        self.common = None
        self.report = {"finished_worktrees": [], "skipped_finished_worktrees": [],
                       "unknown_finished_worktrees": [],
                       "finished_scan": "incomplete" if pr_unavailable else "complete"}

    def git(self, *args, worktree=None):
        return checked(["git", "-C", worktree or self.root, *args], self.root)

    def worktrees(self):
        raw = self.git("worktree", "list", "--porcelain", "-z")
        if "\0" not in raw:
            raise Unknown("worktree_enumeration_unknown")
        records, row = [], {}
        for field in raw.split("\0"):
            if not field:
                if row:
                    if not row.get("path") or not row.get("head_sha"):
                        raise Unknown("worktree_record_unknown")
                    records.append(row)
                    row = {}
                continue
            if field.startswith("worktree "):
                row["path"] = field[9:]
            elif field.startswith("HEAD "):
                row["head_sha"] = field[5:]
            elif field.startswith("branch refs/heads/"):
                row["branch"] = field[18:]
            elif field == "locked" or field.startswith("locked "):
                row["locked"] = True
            elif field == "detached":
                row["branch"] = ""
        if row or not records:
            raise Unknown("worktree_enumeration_incomplete")
        return records

    def resolve_repo(self):
        if self.repo:
            return
        code, origin, _ = run(["git", "-C", self.root, "remote", "get-url", "origin"], self.root)
        if code == 2:
            raise Skip("no_origin_remote")
        if code:
            raise Unknown("repository_identity_unknown")
        origin = origin.strip()
        match = re.fullmatch(r"(?:https?://|ssh://git@)([^/:]+)[:/]([^/]+/[^/]+?)(?:\.git)?/?", origin)
        if not match:
            match = re.fullmatch(r"git@([^:]+):([^/]+/[^/]+?)(?:\.git)?", origin)
        if not match:
            raise Skip("unsupported_origin")
        self.host, self.repo = match.group(1), match.group(2)
        if not re.fullmatch(r"[A-Za-z0-9.-]+", self.host):
            raise Skip("unsupported_origin")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", self.repo):
            raise Unknown("repository_identity_unknown")

    def gh(self, args):
        if self.pr_unavailable:
            raise Unknown("pr_lookup_unknown")
        self.resolve_repo()
        env = dict(os.environ, GH_HOST=self.host)
        env.pop("GH_REPO", None)
        try:
            value = json.loads(checked(["gh", *args, "--repo", self.host + "/" + self.repo],
                                       self.root, GH_TIMEOUT, env))
        except ValueError as exc:
            raise Unknown("pr_lookup_invalid_json") from exc
        if not isinstance(value, list):
            raise Unknown("pr_lookup_invalid_shape")
        return value

    def terminal_pr(self, branch):
        # Open PR protection includes every author, not just the owner.
        opened = self.gh(["pr", "list", "--head", branch, "--state", "open", "--limit", "1", "--json", "number"])
        if any(not isinstance(row, dict) or not isinstance(row.get("number"), int)
               or isinstance(row["number"], bool) or row["number"] <= 0 for row in opened):
            raise Unknown("open_pr_lookup_invalid_shape")
        if opened:
            raise Skip("open_pr")
        rows = self.gh(["pr", "list", "--head", branch, "--state", "all", "--author", "@me",
                        "--limit", "100", "--json", "number,state,headRefName,headRefOid,isCrossRepository"])
        if any(not isinstance(row, dict) or row.get("headRefName") != branch for row in rows):
            raise Unknown("pr_lookup_out_of_scope")
        if not rows:
            raise Skip("no_finished_pr")
        row = rows[0]
        if row.get("state") not in ("MERGED", "CLOSED"):
            if row.get("state") == "OPEN":
                raise Skip("open_pr")
            raise Unknown("pr_state_unknown")
        if row.get("isCrossRepository") is not False:
            raise Unknown("pr_repository_unknown")
        if (not isinstance(row.get("number"), int) or isinstance(row["number"], bool)
                or row["number"] <= 0 or not isinstance(row.get("headRefOid"), str)
                or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", row["headRefOid"])):
            raise Unknown("pr_metadata_unknown")
        guard = str(Path(__file__).parent.parent / "pr-authorship.sh")
        env = dict(os.environ, GH_HOST=self.host)
        env.pop("GH_REPO", None)
        code, _, _ = run([guard, str(row["number"]), "--repo", self.repo], self.root, GH_TIMEOUT, env)
        if code == 1:
            raise Skip("not_authored")
        if code:
            raise Unknown("authorship_unknown")
        return row

    def pushed(self, head, branch, pr):
        # A freshly observed exact PR head is remote evidence even after a
        # squash merge; requiring ancestry in main would reject every squash.
        if head == pr["headRefOid"]:
            return
        raw = self.git("ls-remote", "--heads", "origin", "refs/heads/" + branch)
        rows = [r.split() for r in raw.splitlines()]
        if not rows:
            raise Skip("unpushed_commits")
        if len(rows) != 1 or len(rows[0]) != 2 or rows[0][1] != "refs/heads/" + branch:
            raise Unknown("remote_check_unknown")
        code, _, _ = run(["git", "-C", self.root, "merge-base", "--is-ancestor", head, rows[0][0]], self.root)
        if code == 1:
            raise Skip("unpushed_commits")
        if code:
            raise Unknown("remote_check_unknown")
        # Pushed new work after the closed PR may still be an unfinished task.
        raise Skip("branch_advanced_after_pr")

    def census(self):
        # A known desktop host without a session-to-worktree binding is not
        # proof of inactivity. A later adapter can establish that binding.
        code, processes, errors = run(["ps", "-axo", "comm="], self.root, LSOF_TIMEOUT)
        if code or errors or not processes.strip():
            raise Unknown("process_check_unknown")
        for name in processes.splitlines():
            name = name.strip()
            if (any("/" + app + ".app/" in name.lower() for app in ("codex", "cursor", "claude"))
                    or name.rsplit("/", 1)[-1] in ("Codex", "Cursor", "Claude")):
                raise Unknown("desktop_session_liveness_unknown")
        code, output, errors = run(["lsof", "-nP", "-a", "-d", "cwd", "-F", "pn"], self.root, LSOF_TIMEOUT)
        if code or errors or not output.strip():
            raise Unknown("process_check_unknown")
        paths, pid, has_path = [], None, False
        for line in output.splitlines():
            if line.startswith("p") and line[1:].isdigit():
                if pid is not None and not has_path:
                    raise Unknown("process_check_unknown")
                pid, has_path = line[1:], False
            elif line.startswith("n/") and pid is not None:
                paths.append(line[1:])
                has_path = True
            else:
                raise Unknown("process_check_unknown")
        if not paths or not has_path:
            raise Unknown("process_check_unknown")
        # Resolve the census in one bounded child; inaccessible/deleted cwd
        # paths make this census unknown rather than masquerading as absence.
        program = "from pathlib import Path; import json,sys; print(json.dumps([str(Path(p).resolve(strict=True)) for p in json.loads(sys.argv[1])]))"
        resolved = checked([sys.executable, "-c", program, json.dumps(paths)], self.root, LSOF_TIMEOUT)
        self.cwds = json.loads(resolved)

    def check_files(self, path):
        for flags in (("diff", "--quiet", "--ignore-submodules=none"),
                      ("diff", "--cached", "--quiet", "--ignore-submodules=none")):
            code, _, _ = run(["git", "-C", path, *flags], self.root)
            if code == 1:
                raise Skip("uncommitted_tracked_changes")
            if code:
                raise Unknown("dirty_check_unknown")
        if self.git("ls-files", "--others", "--exclude-standard", "-z", worktree=path):
            raise Skip("untracked_files")
        # Ignored dotenv files are still protected by the repository's safety
        # policy. git worktree remove would otherwise delete them implicitly.
        program = r'''import os,re,stat,sys
errors=[]
logical_bytes=0
for here, dirs, files in os.walk(sys.argv[1], onerror=errors.append):
    dirs[:]=[d for d in dirs if d != '.git']
    for name in dirs+files:
        if (name.lower()=='.env' or name.lower().startswith('.env.')) and not re.fullmatch(r'\.env\.(example|sample|template)', name, re.I):
            sys.exit(10)
    for name in files:
        try:
            meta=os.lstat(os.path.join(here,name))
            if stat.S_ISREG(meta.st_mode) or stat.S_ISLNK(meta.st_mode): logical_bytes+=meta.st_size
        except OSError: errors.append(True)
if not errors: print(logical_bytes)
sys.exit(11 if errors else 0)
'''
        code, sizes, _ = run([sys.executable, "-c", program, path], self.root)
        if code == 10:
            raise Skip("protected_env_files")
        if code:
            raise Unknown("protected_file_check_unknown")
        if not sizes.strip().isdigit():
            raise Unknown("workspace_size_unknown")
        return int(sizes.strip())

    def verify(self, row, refresh=False):
        path = canonical(row["path"], self.root)
        if path == self.root:
            raise Skip("main_worktree")
        if self.caller == path or self.caller.startswith(path + "/"):
            raise Skip("caller_worktree")
        branch = row.get("branch", "")
        if not branch:
            raise Skip("detached_head")
        if branch in ("main", "master", "develop"):
            raise Skip("protected_branch")
        if row.get("locked"):
            raise Skip("locked")
        if any(part in path for part in ("/.codex/worktrees/", "/.cursor/worktrees/")):
            raise Unknown("desktop_session_liveness_unknown")
        common = self.git("rev-parse", "--git-common-dir", worktree=path).strip()
        if canonical(os.path.join(path, common), self.root) != self.common:
            raise Unknown("worktree_repository_unknown")
        self.check_files(path)
        actual_branch = self.git("symbolic-ref", "--short", "HEAD", worktree=path).strip()
        head = self.git("rev-parse", "HEAD", worktree=path).strip()
        if actual_branch != branch or head != row["head_sha"]:
            raise Unknown("worktree_head_changed")
        pr = self.terminal_pr(branch)
        self.pushed(head, branch, pr)
        if refresh:
            self.check_files(path)
        if refresh or self.cwds is None:
            self.census()
        if any(cwd == path or cwd.startswith(path + "/") for cwd in self.cwds):
            raise Skip("live_process")
        stamp = self.git("log", "-1", "--format=%ct", head).strip()
        if not stamp.isdigit():
            raise Unknown("commit_timestamp_unknown")
        return {"path": path, "branch": branch, "head_sha": head,
                "pr_number": pr["number"], "pr_state": pr["state"], "last_commit_ts": int(stamp)}

    def record(self, row, reason, unknown=False):
        key = "unknown_finished_worktrees" if unknown else "skipped_finished_worktrees"
        self.report[key].append({"path": row.get("path", self.root), "branch": row.get("branch", ""), "reason": str(reason)})
        if unknown:
            self.report["finished_scan"] = "incomplete"

    def delete_branch(self, candidate):
        """Git checkout protection plus an expected-tip check under the ref lock."""
        anchor = "refs/claude/finished-cleanup/" + uuid.uuid4().hex
        with tempfile.TemporaryDirectory(prefix="finished-ref-guard-") as directory:
            temporary = Path(directory)
            program = temporary / "guard.py"
            program.write_text(REF_TRANSACTION_GUARD, encoding="utf-8")
            hook = temporary / "reference-transaction"
            hook.write_text('#!/bin/sh\nexec "$CLAUDE_FINISHED_REF_GUARD_PYTHON" "$CLAUDE_FINISHED_REF_GUARD_PROGRAM" "$@"\n')
            hook.chmod(0o700)
            marker = temporary / "hook-supported"
            prefix = "CLAUDE_FINISHED_REF_GUARD_"
            env = dict(os.environ)
            env.update({
                prefix + "PYTHON": sys.executable, prefix + "PROGRAM": str(program),
                prefix + "REF": "refs/heads/" + candidate["branch"],
                prefix + "SHA": candidate["head_sha"], prefix + "ANCHOR": anchor,
                prefix + "MARKER": str(marker),
                prefix + "CONFIG_PRESENT": "1" if "GIT_CONFIG_PARAMETERS" in os.environ else "0",
                prefix + "CONFIG": os.environ.get("GIT_CONFIG_PARAMETERS", ""),
            })
            git = ["git", "-C", self.root, "-c", "core.hooksPath=" + str(temporary)]
            # A private anchor creation proves this Git/backend executes the
            # guard before any real branch deletion. Its hook sees the same
            # original repository policy as an ordinary reference update.
            checked([*git, "update-ref", anchor, candidate["head_sha"],
                     "0" * len(candidate["head_sha"])], self.root, env=env)
            try:
                if not marker.is_file():
                    raise Unknown("reference_transaction_guard_unavailable")
                return run([*git, "-c", "branch." + candidate["branch"] + ".remote=.",
                            "-c", "branch." + candidate["branch"] + ".merge=" + anchor,
                            "branch", "-d", "--", candidate["branch"]], self.root, env=env)
            finally:
                checked([*git, "update-ref", "--no-deref", "-d", anchor,
                         candidate["head_sha"]], self.root, env=env)

    def detect(self):
        self.root = canonical(self.root, self.root)
        self.caller = canonical(self.caller, self.root)
        if self.caller != canonical(os.getcwd(), self.root):
            raise Unknown("caller_context_mismatch")
        self.common = canonical(os.path.join(self.root, self.git("rev-parse", "--git-common-dir").strip()), self.root)
        wanted = None
        if self.only is not None:
            wanted = set()
            for item in self.only:
                if os.path.islink(os.path.normpath(os.path.join(self.root, item))):
                    # A named path swapped for a link could resolve to another registered
                    # worktree: never follow it, so it matches nothing.
                    wanted.add(item)
                    continue
                try:
                    wanted.add(canonical(item, self.root))
                except Unknown:
                    wanted.add(item)  # unreadable or gone: matches no registered worktree
        matched = set()
        for row in self.worktrees():
            if wanted is not None:
                try:
                    here = canonical(row["path"], self.root)
                except Unknown as exc:
                    # Unreadable: never verify or remove it. It only makes the scan incomplete when
                    # it is literally one of the paths requested.
                    if row["path"] in self.only:
                        self.record(row, exc, True)
                    continue
                if here not in wanted:
                    continue
                matched.add(here)
            try:
                self.report["finished_worktrees"].append(self.verify(row))
            except Skip as exc:
                self.record(row, exc)
            except Unknown as exc:
                self.record(row, exc, True)
        if wanted is not None:
            for item in sorted(wanted - matched):
                self.record({"path": item}, "only_path_not_registered")
        return self.report

    def apply(self):
        outcomes = self.report["finished_apply"] = []
        for candidate in self.report["finished_worktrees"]:
            item = {"path": candidate["path"], "branch": candidate["branch"]}
            try:
                rows = [r for r in self.worktrees() if r["path"] == candidate["path"]]
                if len(rows) != 1 or rows[0]["head_sha"] != candidate["head_sha"]:
                    raise Unknown("worktree_changed_before_remove")
                verified = self.verify(rows[0], refresh=True)
                if verified != candidate:
                    raise Unknown("finished_evidence_changed_before_remove")
                if self.git("rev-parse", "HEAD", worktree=candidate["path"]).strip() != candidate["head_sha"]:
                    raise Unknown("head_changed_before_remove")
                # The cwd census can be slow; repeat protected-file/dirty checks
                # after it, immediately before handing the path to Git.
                logical_bytes = self.check_files(candidate["path"])
                item["removal_attempted"] = True
                code, _, errors = run(["git", "-C", self.root, "worktree", "remove", candidate["path"]], self.root, REMOVE_TIMEOUT)
                if code:
                    item.update(outcome="failed", reason="worktree_remove_failed", detail=errors[:4000])
                    # List a refused path regardless of the Git message's
                    # locale. Never follow an error with forced deletion.
                    _, entries, _ = run(["ls", "-la", "--", candidate["path"]], self.root)
                    if entries:
                        item["remaining_entries"] = entries[:4000]
                    outcomes.append(item)
                    continue
                item["worktree_removed"] = True
                item["logical_bytes_reclaimed"] = logical_bytes
                # Recheck the ref after removal; never delete a branch whose
                # tip changed underneath us. No remote branch operation exists.
                current = self.git("rev-parse", "refs/heads/" + candidate["branch"]).strip()
                if current != candidate["head_sha"]:
                    item.update(outcome="failed", reason="worktree_removed_branch_changed")
                elif any(r.get("branch") == candidate["branch"] for r in self.worktrees()):
                    item.update(outcome="failed", reason="worktree_removed_branch_checked_out")
                else:
                    # branch -d owns the checkout guard; the transaction hook
                    # independently rejects a tip that advanced after its merge
                    # check. The private upstream also supports squash merges.
                    code, _, errors = self.delete_branch(candidate)
                    item.update(outcome="removed" if code == 0 else "failed",
                                reason="finished" if code == 0 else "worktree_removed_branch_retained")
                    if code:
                        item["detail"] = errors[:4000]

            except Skip as exc:
                item.update(outcome="failed" if item.get("removal_attempted") else "skipped", reason=str(exc))
            except Unknown as exc:
                self.record(candidate, exc, True)
                item.update(outcome="failed" if item.get("removal_attempted") else "skipped", reason=str(exc))
            outcomes.append(item)


def emit(report, as_json):
    if as_json:
        print(json.dumps(report, ensure_ascii=True))
        return
    print("Finished worktrees:")
    for row in report["finished_worktrees"]:
        print("  " + row["path"] + " — " + row["pr_state"] + " PR #" + str(row["pr_number"]))
    if not report["finished_worktrees"]:
        print("  none")
    for row in report["unknown_finished_worktrees"]:
        print("unknown: " + row["path"] + " — " + row["reason"])
    for row in report.get("finished_apply", []):
        print(row["outcome"] + ": " + row["path"] + " — " + row["reason"])
        if row.get("remaining_entries"):
            print(row["remaining_entries"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--caller", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--pr-lookup-unavailable", action="store_true")
    parser.add_argument("--only", action="append", metavar="PATH",
                        help="restrict the scan to this worktree path (repeatable); never widens")
    args = parser.parse_args()
    if args.only is not None and any(not item.strip() for item in args.only):
        parser.error("--only requires a non-empty path")
    sweep = Sweep(args.root, args.caller, args.pr_lookup_unavailable, args.only)
    try:
        sweep.detect()
        if args.apply:
            sweep.apply()
    except (Unknown, OSError, ValueError, TypeError, KeyError) as exc:
        sweep.record({"path": args.root}, exc, True)
    report = sweep.report
    emit(report, args.json)
    if args.apply:
        return int(report["finished_scan"] != "complete" or any(r["outcome"] == "failed" for r in report.get("finished_apply", [])))
    return int(bool(report["finished_worktrees"]) or report["finished_scan"] != "complete")


def interrupted(_signum, _frame):
    raise KeyboardInterrupt()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
