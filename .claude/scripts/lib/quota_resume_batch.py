"""Prepare and dispatch explicitly approved batches of verified Claude /end stops."""

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
import uuid
from dataclasses import asdict
from pathlib import Path

import quota_resume_approval as approval
import quota_resume_launcher as launch
import quota_resume_process as process
import quota_resume_roster as roster
import quota_resume_terminal as terminal


SCRIPT = Path(__file__).resolve()
SCRIPTS = SCRIPT.parent.parent
MANIFEST_NAME = re.compile(r"worker-[0-9a-f]{32}\.json\Z")
PROOF_FIELDS = {"stop", "origin", "handoff", "gate", "directory"}
STATE_SELECTORS = ("CLAUDE_SESSION_STATE_FILE", "CLAUDE_EXECUTION_PAUSE_MARKER_DIR",
                   "AI_QUOTAS_CONFIG", "AI_QUOTAS_PROFILE_ROOT")


def selector_values(environment=None):
    environment = os.environ if environment is None else environment
    values = {}
    for key in STATE_SELECTORS:
        value = environment.get(key)
        if value:
            values[key] = str(approval.canonical_path(value))
    return values


def private_json(path, limit=65536):
    value = json.loads(launch.read_private(path, limit))
    if not isinstance(value, dict):
        raise ValueError("private resume record must contain an object")
    return value


def directory_identity(path):
    value = approval.canonical_path(path)
    if not value.is_dir() or value.resolve(strict=True) != value:
        raise ValueError("the original working directory cannot be verified")
    info = value.stat()
    return [info.st_dev, info.st_ino]


def gate_proof(repo, session):
    result = subprocess.run([str(SCRIPTS / "execution-pause.sh"), "--repo", repo,
                             "--session", session, "--end-proof"], capture_output=True, timeout=8, check=True)
    proof = json.loads(result.stdout)
    if not isinstance(proof, dict) or proof.get("session_id") != session or proof.get("command") != "end":
        raise ValueError("the exact /end gate could not be verified")
    return approval.digest(proof)


class BatchState:
    def __init__(self, home, accounts, *, write=False, check_gate=gate_proof,
                 check_origin=process.origin_exited):
        self.home = home
        self.accounts = accounts
        self.root = roster.roster_path(home, write=write)
        self.stops = self.root / "batch-stops"
        self.receipts = self.root / "batch-receipts"
        self.check_gate = check_gate
        self.check_origin = check_origin

    def source(self, profile):
        primary = self.home / ".claude"
        try:
            return roster.source_account(self.accounts, profile)
        except ValueError:
            if roster.physical_directory(profile) != primary:
                raise
            return roster.source_account(self.accounts, profile, roster.primary_account_email(self.home))

    def end_record(self, session):
        if not approval.UUID.fullmatch(session):
            raise ValueError("a native session is required")
        row = private_json(self.root / f"{session}.json", 16384)
        if row.get("session_id") != session or row.get("checkpoint") != "end":
            raise ValueError("a verified /end roster record is required")
        return row

    def record(self, session, native_session, repo, cwd, handoff, source, profile,
               capture=process.capture_origin):
        # /end calls only after both gates, terminal tasks and canonical handoff.
        row = self.end_record(session)
        local = str(roster.local_handoff(handoff, self.root))
        if (row.get("cwd") != cwd or row.get("handoff") != local
                or row.get("source_account") != source or row.get("source_profile") != str(profile)):
            raise ValueError("the /end handoff does not match the roster")
        origin = capture(session, native_session, repo)
        stop = approval.Stop(source, str(profile), repo, session, origin["generation"], cwd)
        evidence = dict(stop=asdict(stop), origin=origin, handoff=local,
                        gate=self.check_gate(repo, session), directory=directory_identity(cwd))
        with approval.receipt_directory(self.stops) as descriptor:
            temporary = f".proof-{uuid.uuid4().hex}"
            try:
                if not approval.write_once(descriptor, temporary, evidence):
                    raise ValueError("could not stage the /end proof")
                os.replace(temporary, f"{session}.json", src_dir_fd=descriptor, dst_dir_fd=descriptor)
                os.fsync(descriptor)
            finally:
                try:
                    os.unlink(temporary, dir_fd=descriptor)
                except FileNotFoundError:
                    pass

    def verify(self, stop, target):
        # Keep the preview read-only and recheck all exact evidence before exec.
        if self.stops.is_symlink() or self.root.is_symlink():
            return False
        data = private_json(self.stops / f"{stop.session}.json", 16384)
        row = self.end_record(stop.session)
        source, profile = self.source(stop.profile)
        if (set(data) != PROOF_FIELDS or data["stop"] != asdict(stop)
                or source != stop.account or str(profile) != stop.profile
                or row.get("source_account") != source or row.get("source_profile") != stop.profile
                or row.get("cwd") != stop.cwd or row.get("handoff") != data["handoff"]
                or str(roster.local_handoff(data["handoff"], self.root)) != data["handoff"]
                or data["directory"] != directory_identity(stop.cwd)
                or data["gate"] != self.check_gate(stop.repo, stop.session)
                or not isinstance(data["origin"], dict) or data["origin"].get("generation") != stop.generation):
            return False
        label = roster.account_for_launcher(self.accounts, source, target.launcher)
        target_profile = self.accounts[label][1]
        projects = roster.shared_projects(profile)
        return (target_profile is not None and str(target_profile) == target.profile
                and projects == roster.shared_projects(target_profile)
                and roster.has_transcript(projects, stop.session)
                and self.check_origin(data["origin"], stop.cwd, stop.session, stop.repo) is True)

    def candidates(self, source, profile, target):
        if self.stops.is_symlink():
            raise ValueError("the /end proof directory is not trusted")
        candidates = []
        for path in sorted(self.stops.glob("*.json")):
            if not approval.UUID.fullmatch(path.stem):
                continue
            try:
                raw = private_json(path, 16384)
                stop = approval.Stop(**raw["stop"])
                if (path.stem == stop.session and stop.account == source and stop.profile == str(profile)
                        and self.verify(stop, target)):
                    candidates.append(stop)
            except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError, process.EvidenceUnavailable):
                continue
        return candidates


def choose_launcher(state, source, name, path=None):
    label = roster.account_for_launcher(state.accounts, source, name)
    profile = state.accounts[label][1]
    if profile is None:
        raise ValueError("the registered target profile is unavailable")
    if path is None:
        path = os.environ.get("AI_QUOTAS_LAUNCHERS_FILE") or state.home / ".claude/ai-quotas/launchers.zsh"
    return launch.snapshot_launcher(path, name, label, str(profile), launch.trusted_cli(state.home))


def worker_files(state, plan, stop, launcher):
    name = f"worker-{uuid.uuid4().hex}"
    manifest = state.receipts / f"{name}.json"
    worker = state.receipts / f"{name}.zsh"
    data = dict(target=asdict(plan.target), stops=[asdict(item) for item in plan.stops],
                approval=plan.approval, session=stop.session, launcher=str(launcher.path))
    selectors = selector_values()
    if approval.digest(selectors) != plan.target.context_proof:
        raise ValueError("the approved state selection changed")
    # New terminal shells need not inherit the manager's environment. Carry
    # only the verified local state path selectors, never auth or session data.
    env = ["/usr/bin/env"]
    for key in STATE_SELECTORS:
        env.extend(("-u", key))
    env.extend(f"{key}={value}" for key, value in selectors.items())
    with approval.receipt_directory(state.receipts, create=False) as descriptor:
        if not approval.write_once(descriptor, manifest.name, data):
            raise ValueError("worker manifest already exists")
        fd = os.open(worker.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=descriptor)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("exec " + shlex.join([*env, sys.executable, "-B", str(SCRIPT), "worker", str(manifest)]) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(descriptor)
    return worker


def run_worker(state, manifest, execute=launch.exec_launcher, now=None):
    path = Path(manifest)
    if (path.parent != state.receipts or not MANIFEST_NAME.fullmatch(path.name)
            or state.receipts.is_symlink()):
        raise ValueError("the approved worker path is not private")
    value = private_json(path)
    if set(value) != {"target", "stops", "approval", "session", "launcher"}:
        raise ValueError("the approved worker manifest is invalid")
    target = approval.Target(**value["target"])
    if target.context_proof != approval.digest(selector_values()):
        raise ValueError("the approved state selection changed")
    stops = [approval.Stop(**item) for item in value["stops"]]
    plan = approval.authorized_plan(target, stops, value["approval"], now)
    selected = next((stop for stop in plan.stops if stop.session == value["session"]), None)
    if selected is None:
        raise ValueError("the worker is not part of the approved batch")
    launcher = choose_launcher(state, selected.account, target.launcher, value["launcher"])
    if launcher.proof != target.launcher_proof or launcher.profile != target.profile:
        raise ValueError("the approved launcher changed")
    directory_fd = os.open(selected.cwd, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        observed = os.fstat(directory_fd)
        exact = [observed.st_dev, observed.st_ino]

        def verify(stop, target):
            return directory_identity(stop.cwd) == exact and state.verify(stop, target)

        stop = approval.consume_worker(target, stops, value["approval"], selected.session,
                                       state.receipts, verify, now=now)
        if stop is None:
            raise ValueError("the worker could not verify and claim the exact reserved stop")
        execute(launcher, stop.session, stop.cwd, directory_fd)
    finally:
        os.close(directory_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    record = sub.add_parser("record", help="record the current native Claude /end proof")
    for name in ("session", "repo", "cwd", "handoff"):
        record.add_argument("--" + name, required=True)
    sub.add_parser("preview", help="read verified stops and show the exact batch").add_argument("--target", required=True)
    apply = sub.add_parser("approve", help="dispatch only the explicitly approved batch")
    apply.add_argument("--target", required=True)
    apply.add_argument("--approval", required=True)
    sub.add_parser("worker", help="run one previously reserved local worker").add_argument("manifest")
    args = parser.parse_args(argv)
    try:
        home = Path.home().resolve(strict=True)
        accounts = roster.registered_accounts(roster.metadata(SCRIPTS / "ai-quotas-setup.sh"))
        state = BatchState(home, accounts, write=args.action != "preview")
        if args.action == "worker":
            run_worker(state, args.manifest)
            return 0
        source, profile = state.source(os.environ.get("CLAUDE_CONFIG_DIR") or str(home / ".claude"))
        if args.action == "record":
            state.record(args.session, os.environ.get("CLAUDE_CODE_SESSION_ID"), args.repo,
                         args.cwd, args.handoff, source, profile)
            return 0
        backend = terminal.discover()
        launcher = choose_launcher(state, source, args.target)
        target = approval.Target(launcher.name, launcher.profile, backend.approval_destination, launcher.proof,
                                 approval.digest(selector_values()))
        stops = state.candidates(source, profile, target)
        if not stops:
            raise ValueError("no verified /end stops are eligible; use the manual roster")
        now = int(time.time())
        if args.action == "preview":
            plan = approval.make_plan(target, stops, now)
            print(json.dumps(dict(target=target.launcher, destination=backend.description,
                                  stops=[{"session": item.session, "cwd": item.cwd} for item in plan.stops],
                                  approval=plan.approval, expires_in_seconds=approval.APPROVAL_SECONDS)))
            return 0
        plan = approval.authorized_plan(target, stops, args.approval, now)

        def dispatch(stop, _target):
            return backend.submit(worker_files(state, plan, stop, launcher))

        results = approval.execute_approved(target, stops, args.approval, state.receipts,
                                            state.verify, dispatch, now=now)
        print(json.dumps(dict(target=target.launcher, results=results)))
    except (OSError, TypeError, KeyError, ValueError, subprocess.SubprocessError,
            process.EvidenceUnavailable, terminal.BackendUnavailable) as error:
        # No raw subprocess, config, account or manifest contents reach stderr.
        detail = str(error) if type(error) is ValueError else "verified batch evidence is unavailable"
        print(f"quota-resume-batch: {detail}", file=sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    sys.exit(main())
