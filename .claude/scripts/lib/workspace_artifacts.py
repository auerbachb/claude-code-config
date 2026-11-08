"""Finished artifact pass for the workspace cadence; ambiguity retains data."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location("finished_cleanup", Path(__file__).with_name("stale-cleanup-finished.py"))
finished = importlib.util.module_from_spec(spec)
spec.loader.exec_module(finished)


class Artifacts:
    def __init__(self, root, home, now, apply=False, limit=100, cursor=0):
        self.root, self.home, self.now, self.apply = Path(root), Path(home), now, apply
        if not self.root.is_absolute() or not self.home.is_absolute():
            raise finished.Unknown("artifact_root_must_be_absolute")
        self.sweep = finished.Sweep(str(self.root), str(self.root))
        self.sweep.resolve_repo()
        self.sweep.common = finished.canonical(os.path.join(str(self.root), self.sweep.git("rev-parse", "--git-common-dir").strip()), str(self.root))
        self.limit, self.items, self.truncated = limit, [], False
        self.operations, self.cursor = [], cursor

    def terminal(self, number):
        self.sweep.resolve_repo()
        env = dict(os.environ, GH_HOST=self.sweep.host)
        env.pop("GH_REPO", None)
        raw = finished.checked(["gh", "pr", "view", str(number), "--repo", self.sweep.host + "/" + self.sweep.repo,
                                "--json", "number,state,headRefOid"], str(self.root), finished.GH_TIMEOUT, env)
        row = json.loads(raw)
        if not isinstance(row, dict) or type(row.get("number")) is not int or row.get("number") != number:
            raise finished.Unknown("pr_identity_unknown")
        if row.get("state") == "OPEN":
            raise finished.Skip("open_pr")
        if row.get("state") not in ("MERGED", "CLOSED"):
            raise finished.Unknown("pr_state_unknown")
        return row

    @staticmethod
    def private_json(path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            meta = os.fstat(stream.fileno())
            if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_nlink != 1:
                raise finished.Unknown("artifact_identity_unknown")
            raw = stream.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise finished.Unknown("artifact_output_limit")
            return json.loads(raw), meta

    def item(self, kind, path, operation):
        self.operations.append((kind, path, operation))

    def process(self, kind, path, operation):
        row = {"kind": kind, "path": str(path), "removed": False, "logical_bytes_reclaimed": 0}
        try:
            operation(row)
            row.setdefault("outcome", "candidate")
            row.setdefault("reason", "finished")
        except finished.Skip as exc:
            row.update(outcome="retained", reason=str(exc))
        except (finished.Unknown, OSError, ValueError, TypeError, KeyError) as exc:
            # No contents or provider values enter the persisted reason.
            reason = str(exc) if isinstance(exc, finished.Unknown) else ("artifact_remove_failed" if row.get("removal_attempted") else "artifact_evidence_unknown")
            row.update(outcome="unknown", reason=reason)
            if row.get("removal_attempted") and row.get("removed") is not True:
                row["removed"] = None
        self.items.append(row)

    def handoff(self, path, row):
        number = int(re.fullmatch(r"pr-([1-9][0-9]*)-handoff\.json", path.name)[1])
        doc, meta = self.private_json(path)
        if (not isinstance(doc, dict) or type(doc.get("pr_number")) is not int or doc.get("pr_number") != number
                or str(doc.get("owner_repo", "")).lower() != self.sweep.repo.lower()
                or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", str(doc.get("head_sha", "")))):
            raise finished.Unknown("handoff_identity_unknown")
        self.terminal(number)
        if self.apply:
            self.terminal(number)
            helper = str(Path(__file__).parents[1] / "handoff-state.sh")
            env = dict(os.environ, HOME=str(self.home))
            row["removal_attempted"] = True
            code, _, _ = finished.run([helper, "--owner-repo", self.sweep.repo, "--require-existing",
                                       "--expect-pr", str(number), "--expect-owner", self.sweep.repo,
                                       "--expect-head", doc["head_sha"], "--delete", str(number)],
                                      str(self.root), env=env)
            if code or path.exists():
                raise finished.Unknown("handoff_delete_refused")
            row.update(outcome="removed", removed=True, logical_bytes_reclaimed=meta.st_size)

    def branch(self, branch, head, row):
        if branch in ("main", "master", "develop"):
            raise finished.Skip("protected_branch")
        if any(r.get("branch") == branch for r in self.sweep.worktrees()):
            raise finished.Skip("branch_checked_out")
        pr = self.sweep.terminal_pr(branch)
        self.sweep.pushed(head, branch, pr)
        if self.apply:
            # Repeat all remote/PR checks; the existing ref transaction guard
            # also checks expected tip and Git's own checkout protection.
            current = self.sweep.git("rev-parse", "refs/heads/" + branch).strip()
            if current != head:
                raise finished.Unknown("branch_changed_before_remove")
            self.sweep.pushed(head, branch, self.sweep.terminal_pr(branch))
            row["removal_attempted"] = True
            code, _, _ = self.sweep.delete_branch({"branch": branch, "head_sha": head})
            if code:
                raise finished.Unknown("branch_delete_refused")
            row.update(outcome="removed", removed=True)

    def registration_metadata(self, candidate):
        matches = []
        registry = Path(self.sweep.common) / "worktrees"
        for entry in registry.iterdir():
            if entry.is_symlink() or not entry.is_dir():
                continue
            fd = os.open(entry / "gitdir", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                meta = os.fstat(stream.fileno())
                if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid():
                    raise finished.Unknown("orphan_metadata_unknown")
                raw = stream.read(4097).decode("utf-8").strip()
            if len(raw) <= 4096 and Path(raw).resolve() == (Path(candidate["path"]) / ".git").resolve():
                matches.append(entry)
        if len(matches) != 1:
            raise finished.Unknown("orphan_metadata_identity_unknown")
        entry = matches[0]
        if any((entry / name).exists() for name in ("MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply", "index.lock")):
            raise finished.Skip("orphan_operation_in_progress")
        git = ["git", "--git-dir", str(entry), "--work-tree", candidate["path"]]
        head = finished.checked([*git, "rev-parse", "HEAD"], str(self.root)).strip()
        if head != candidate["head_sha"]:
            raise finished.Unknown("orphan_head_changed")
        code, _, _ = finished.run([*git, "diff", "--cached", "--quiet", "--no-ext-diff", "HEAD"], str(self.root))
        if code == 1:
            raise finished.Skip("orphan_staged_changes")
        if code:
            raise finished.Unknown("orphan_index_unknown")
        return entry

    def registration_inactive(self, entry, path):
        self.sweep.census()
        for cwd in self.sweep.cwds:
            current = Path(cwd)
            if current == path or path in current.parents:
                raise finished.Skip("live_process")
            # A manually moved checkout may still point at this registration.
            # A complete cwd census must protect that live binding too.
            for parent in (current, *current.parents):
                gitfile = parent / ".git"
                if not gitfile.is_file():
                    continue
                if gitfile.is_symlink():
                    raise finished.Unknown("live_checkout_binding_unknown")
                fd = os.open(gitfile, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    raw = stream.read(4097).decode("utf-8").strip()
                if raw.startswith("gitdir: ") and len(raw) <= 4096:
                    target = Path(raw[8:])
                    if not target.is_absolute(): target = parent / target
                    if target.resolve() == entry.resolve():
                        raise finished.Skip("live_process")
                break

    def registration(self, candidate, row):
        path, branch = Path(candidate["path"]), candidate.get("branch")
        if candidate.get("locked"):
            raise finished.Skip("locked")
        if not branch or branch in ("main", "master", "develop"):
            raise finished.Skip("protected_branch")
        if path.exists() or path.is_symlink() or not path.parent.is_dir():
            raise finished.Unknown("orphan_absence_unknown")
        metadata = self.registration_metadata(candidate)
        pr = self.sweep.terminal_pr(branch)
        self.sweep.pushed(candidate["head_sha"], branch, pr)
        self.registration_inactive(metadata, path)
        if self.apply:
            fresh = [r for r in self.sweep.worktrees() if r["path"] == str(path)]
            if len(fresh) != 1 or fresh[0] != candidate or path.exists() or path.is_symlink():
                raise finished.Unknown("orphan_changed_before_remove")
            self.sweep.pushed(candidate["head_sha"], branch, self.sweep.terminal_pr(branch))
            metadata = self.registration_metadata(candidate)
            self.registration_inactive(metadata, path)
            row["removal_attempted"] = True
            code, _, _ = finished.run(["git", "-C", str(self.root), "worktree", "remove", "--", str(path)], str(self.root))
            if code:
                _, entries, _ = finished.run(["ls", "-la", "--", str(path)], str(self.root))
                row["remaining_entries"] = entries[:4000]
                raise finished.Unknown("orphan_remove_refused")
            row.update(outcome="removed", removed=True)

    @staticmethod
    def fingerprint(meta):
        identity = (meta.st_dev, meta.st_ino, meta.st_mode, meta.st_uid)
        return identity if stat.S_ISDIR(meta.st_mode) else identity + (meta.st_nlink, meta.st_size, meta.st_mtime_ns)

    @staticmethod
    def inventory(path):
        result, errors = [], []
        for here, dirs, files in os.walk(path, followlinks=False, onerror=errors.append):
            dirs.sort()
            files.sort()
            for name in dirs + files:
                entry = Path(here) / name
                if name == ".claude-workspace-artifact.json" and entry.parent != path:
                    raise finished.Skip("nested_scratch_ownership")
                if name == ".git" or name.lower() == ".env" or name.lower().startswith(".env."):
                    raise finished.Skip("protected_workspace_files")
                meta = entry.lstat()
                if (meta.st_uid != os.getuid() or stat.S_ISLNK(meta.st_mode)
                        or not (stat.S_ISDIR(meta.st_mode) or stat.S_ISREG(meta.st_mode))
                        or (stat.S_ISREG(meta.st_mode) and meta.st_nlink != 1)):
                    raise finished.Unknown("scratch_entry_identity_unknown")
                result.append((entry, Artifacts.fingerprint(meta)))
        if errors:
            raise finished.Unknown("scratch_enumeration_unknown")
        return result

    def scratch_allowed(self, path):
        for base, pattern in self.scratch_locations():
            if base.is_symlink(): continue
            base = base.resolve()
            if base not in path.parents: continue
            parts = path.relative_to(base).parts
            if pattern == "*": return True
            if parts[0].startswith("claude-"):
                # Native per-user containers hold multiple sessions. Only a
                # session subtree can be attributed to one owning process.
                if re.fullmatch(r"claude-[0-9]+", parts[0]) and len(parts) < 3: continue
                return True
        return False

    def scratch(self, path, row):
        if any(part == ".git" or part.lower() == ".env" or part.lower().startswith(".env.") for part in path.parts):
            raise finished.Skip("protected_workspace_files")
        meta = path.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o022:
            raise finished.Unknown("scratch_identity_unknown")
        # The process census is canonical (macOS /var -> /private/var).
        # Compare one namespace before treating an absent cwd match as idle.
        path = path.resolve(strict=True)
        if not self.scratch_allowed(path):
            if re.fullmatch(r"claude-[0-9]+", path.name) and any(pattern == "claude-*" and path.parent == base.resolve() for base, pattern in self.scratch_locations()):
                raise finished.Skip("shared_session_container")
            raise finished.Unknown("scratch_outside_roots")
        if any(part == ".git" or part.lower() == ".env" or part.lower().startswith(".env.") for part in path.parts):
            raise finished.Skip("protected_workspace_files")
        if self.now - meta.st_mtime < 7 * 86400:
            raise finished.Skip("scratch_recent")
        doc, _ = self.private_json(path / ".claude-workspace-artifact.json")
        if (not isinstance(doc, dict) or doc.get("schema_version") != "1.0"
                or str(doc.get("owner_repo", "")).lower() != self.sweep.repo.lower()
                or doc.get("owner_host", "github.com") != self.sweep.host):
            raise finished.Unknown("scratch_owner_unknown")
        pid, number = doc.get("owner_pid"), doc.get("pr_number")
        if type(pid) is not int or not 1 < pid < 2**31 or type(number) is not int or number <= 0:
            raise finished.Unknown("scratch_owner_unknown")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise finished.Skip("live_owner_process")
        self.terminal(number)
        self.sweep.census()
        if any(cwd == str(path) or cwd.startswith(str(path) + "/") for cwd in self.sweep.cwds):
            raise finished.Skip("live_process")
        before = self.inventory(path)
        if any(entry.lstat().st_mtime > self.now - 7 * 86400 for entry, _ in before):
            raise finished.Skip("scratch_recent_contents")
        if self.apply:
            if self.inventory(path) != before:
                raise finished.Unknown("scratch_changed_before_remove")
            self.terminal(number)
            if self.fingerprint(path.lstat()) != self.fingerprint(meta):
                raise finished.Unknown("scratch_root_changed_before_remove")
            row["removal_attempted"] = True
            for entry, old in sorted(before, key=lambda item: len(item[0].parts), reverse=True):
                if self.fingerprint(entry.lstat()) != old:
                    raise finished.Unknown("scratch_changed_during_remove")
                if stat.S_ISDIR(old[2]):
                    entry.rmdir()
                else:
                    entry.unlink()
                    row["logical_bytes_reclaimed"] += old[-2]
            path.rmdir()
            row.update(outcome="removed", removed=True)

    def scratch_locations(self):
        roots = [(self.home / ".claude/scratch", "*"), (Path("/tmp").resolve(), "claude-*")]
        native = Path(tempfile.gettempdir()).resolve()
        if native != Path("/tmp").resolve(): roots.append((native, "claude-*"))
        override = os.environ.get("WORKSPACE_SWEEP_SCRATCH_ROOTS_JSON")
        if override:
            paths = json.loads(override)
            if not isinstance(paths, list) or len(paths) > 20 or any(not isinstance(p, str) or not Path(p).is_absolute() for p in paths):
                raise finished.Unknown("scratch_roots_unknown")
            roots = [(Path(p), "*") for p in paths]
        return roots

    def registered_scratch(self):
        path = self.home / ".claude/workspace-sweep/scratch-artifacts.json"
        if not path.exists(): return []
        document, _ = self.private_json(path)
        if (not isinstance(document, dict) or document.get("schema_version") != "1.0"
                or not isinstance(document.get("repositories"), dict)):
            raise finished.Unknown("scratch_registry_unknown")
        paths = document["repositories"].get(self.sweep.host + "/" + self.sweep.repo, [])
        if not isinstance(paths, list) or len(paths) > 1000 or any(not isinstance(p, str) or not Path(p).is_absolute() for p in paths):
            raise finished.Unknown("scratch_registry_unknown")
        return [Path(p) for p in paths]

    def register_scratch(self, path, number, owner_pid):
        """Explicitly bind ephemeral scratch to a known durable ancestor process."""
        import workspace_sweep as cadence
        if not Path(path).is_absolute() or type(number) is not int or number <= 0 or not 1 < owner_pid < 2**31:
            raise finished.Unknown("scratch_registration_identity_unknown")
        original = Path(path)
        meta = original.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o022:
            raise finished.Unknown("scratch_registration_directory_unsafe")
        path = original.resolve(strict=True)
        if any(part == ".git" or part.lower() == ".env" or part.lower().startswith(".env.") for part in path.parts):
            raise finished.Skip("protected_workspace_files")
        if not self.scratch_allowed(path):
            raise finished.Unknown("scratch_registration_outside_roots")
        current = os.getppid()
        for _ in range(32):
            raw = finished.checked(["ps", "-p", str(current), "-o", "ppid=,uid="], str(self.root), 2).split()
            if len(raw) != 2 or not all(value.isdigit() for value in raw) or int(raw[1]) != os.getuid():
                raise finished.Unknown("scratch_registration_owner_unknown")
            if current == owner_pid: break
            current = int(raw[0])
            if current <= 1: raise finished.Unknown("scratch_registration_owner_not_ancestor")
        else: raise finished.Unknown("scratch_registration_owner_not_ancestor")
        self.inventory(path)
        document = dict(schema_version="1.0", owner_repo=self.sweep.repo, owner_host=self.sweep.host,
                        pr_number=number, owner_pid=owner_pid)
        marker = path / ".claude-workspace-artifact.json"
        if marker.exists() or marker.is_symlink():
            existing, _ = self.private_json(marker)
            if existing != document: raise finished.Unknown("scratch_registration_conflict")
        base = self.home / ".claude/workspace-sweep"
        cadence.private_dir(base)
        with cadence.lock(base / "scratch-registry.lock", wait=5):
            registry = base / "scratch-artifacts.json"
            records = cadence.load(registry, {"schema_version":"1.0","repositories":{}}, strict=True)
            if not isinstance(records, dict) or records.get("schema_version") != "1.0" or not isinstance(records.get("repositories"), dict):
                raise finished.Unknown("scratch_registry_unknown")
            key = self.sweep.host + "/" + self.sweep.repo
            paths = records["repositories"].get(key, [])
            if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
                raise finished.Unknown("scratch_registry_unknown")
            records["repositories"][key] = list(dict.fromkeys([*paths, str(path)]))
            if len(records["repositories"][key]) > 1000 or len(json.dumps(records).encode()) > 1024 * 1024:
                raise finished.Unknown("scratch_registry_limit")
            # Publish discovery first: an interrupted marker write remains
            # indexed and unknown, never silently eligible for deletion.
            cadence.save(registry, records)
            if not marker.exists():
                fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, "w") as stream:
                    json.dump(document, stream)
                    stream.flush()
                    os.fsync(stream.fileno())

    def prune_registered_scratch(self, candidates):
        missing = set()
        for path in candidates:
            try: path.lstat()
            except FileNotFoundError: missing.add(str(path.resolve()))
        if not missing: return
        import workspace_sweep as cadence
        base = self.home / ".claude/workspace-sweep"
        registry = base / "scratch-artifacts.json"
        with cadence.lock(base / "scratch-registry.lock", wait=5):
            records = cadence.load(registry, None, strict=True)
            if not isinstance(records, dict) or not isinstance(records.get("repositories"), dict):
                raise finished.Unknown("scratch_registry_unknown")
            key = self.sweep.host + "/" + self.sweep.repo
            before = records["repositories"].get(key, [])
            if not isinstance(before, list): raise finished.Unknown("scratch_registry_unknown")
            after = [p for p in before if p not in missing]
            if before != after:
                records["repositories"][key] = after
                cadence.save(registry, records)

    @staticmethod
    def unknown(reason):
        raise finished.Unknown(reason)

    def scan(self):
        handoffs = self.home / ".claude/handoffs" / self.sweep.repo
        if handoffs.is_symlink():
            self.item("handoff_directory", handoffs, lambda row: self.unknown("handoff_directory_symlink"))
        elif handoffs.is_dir():
            for path in sorted(handoffs.glob("pr-*-handoff.json")):
                if re.fullmatch(r"pr-[1-9][0-9]*-handoff\.json", path.name):
                    self.item("handoff", path, lambda row, path=path: self.handoff(path, row))
        trees = self.sweep.worktrees()
        for candidate in trees:
            path = Path(candidate["path"])
            if not path.exists():
                self.item("orphan_registration", path, lambda row, candidate=candidate: self.registration(candidate, row))
        # Missing registration means Git cannot establish dirty/unpushed state.
        # Include these in cadence reporting, never turn absence into permission
        # to recursively delete source files outside git worktree remove.
        base = self.root / ".claude/worktrees"
        if base.is_dir() and not base.is_symlink():
            for path in sorted(base.iterdir()):
                gitfile = path / ".git"
                if path.is_dir() and not path.is_symlink() and gitfile.is_file() and not gitfile.is_symlink():
                    fd = os.open(gitfile, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    with os.fdopen(fd, "rb") as stream:
                        raw = stream.read(4097).decode("utf-8").strip()
                    target = Path(raw[8:]) if raw.startswith("gitdir: ") else None
                    if target and not target.is_absolute():
                        target = path / target
                    owned = target and os.path.commonpath([str(target.resolve()), self.sweep.common]) == self.sweep.common
                    if len(raw) <= 4096 and owned and not target.exists():
                        self.item("orphan_checkout", path, lambda row: self.unknown("orphan_checkout_work_state_unverifiable"))
        for line in self.sweep.git("for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads").splitlines():
            branch, head = line.rsplit(" ", 1)
            if not any(r.get("branch") == branch for r in trees):
                self.item("local_branch", branch, lambda row, branch=branch, head=head: self.branch(branch, head, row))
        registered_paths = self.registered_scratch()
        scratch_paths = list(registered_paths)
        for base, pattern in self.scratch_locations():
            if not base.is_dir() or base.is_symlink(): continue
            scratch_paths.extend(path for path in sorted(base.glob(pattern)) if path.is_dir() and not path.is_symlink() and path.lstat().st_uid == os.getuid())
        seen = set()
        for path in scratch_paths:
            identity = str(path.resolve())
            if identity not in seen:
                seen.add(identity)
                self.item("scratch", path, lambda row, path=path: self.scratch(path, row))
        count = len(self.operations)
        start = self.cursor % count if count else 0
        selected = (self.operations[start:] + self.operations[:start])[:self.limit]
        for operation in selected:
            self.process(*operation)
        self.truncated = len(selected) < count
        try:
            self.prune_registered_scratch(registered_paths)
        except (OSError, ValueError, finished.Unknown):
            self.items.append(dict(kind="scratch_registry", path=str(self.home / ".claude/workspace-sweep/scratch-artifacts.json"),
                                   removed=False, logical_bytes_reclaimed=0, outcome="unknown", reason="scratch_registry_update_failed"))
        return {"artifacts": self.items, "truncated": self.truncated,
                "next_cursor": (start + len(selected)) % count if count else 0,
                "removed": None if any(r["removed"] is None for r in self.items) else sum(r["removed"] is True for r in self.items),
                "known_removed": sum(r["removed"] is True for r in self.items),
                "logical_bytes_reclaimed": None if any(r["removed"] is None and r["kind"] != "scratch" for r in self.items) else sum(r["logical_bytes_reclaimed"] for r in self.items),
                "known_logical_bytes_reclaimed": sum(r["logical_bytes_reclaimed"] for r in self.items)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--now", type=int)
    parser.add_argument("--cursor", type=int, default=0)
    args = parser.parse_args()
    try:
        report = Artifacts(args.root, Path.home(), int(time.time()) if args.now is None else args.now, args.apply, cursor=args.cursor).scan()
        print(json.dumps(report))
        return 0
    except (finished.Unknown, finished.Skip, OSError, ValueError, TypeError, KeyError):
        print(json.dumps({"artifacts": [], "error": "artifact_scan_unavailable", "removed": None,
                          "logical_bytes_reclaimed": None, "truncated": False}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
