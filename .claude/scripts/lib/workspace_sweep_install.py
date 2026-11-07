"""Opt-in launchd installer; dry runs perform no filesystem mutations."""
import argparse
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile

LABEL = "com.user.claude-workspace-sweep"


def launch(*args, check=True):
    result = subprocess.run(["launchctl", *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
    if check and result.returncode:
        raise RuntimeError("launchctl " + args[0] + " failed")
    return result.returncode


def publish(path, body):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".workspace-sweep-")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hour", type=int, default=3)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if not 0 <= args.hour <= 23:
        parser.error("hour must be between 0 and 23")
    if subprocess.check_output(["uname", "-s"], timeout=5).strip() != b"Darwin":
        parser.error("workspace-sweep LaunchAgent requires macOS")
    home = Path.home()
    target = home / "Library/LaunchAgents" / (LABEL + ".plist")
    domain = "gui/" + str(os.getuid())
    service = domain + "/" + LABEL
    if args.uninstall:
        if args.dry_run:
            print("Would uninstall " + str(target) + "; retain registry, state and logs")
            return 0
        launch("bootout", service, check=False)
        if launch("list", LABEL, check=False) == 0:
            raise RuntimeError("LaunchAgent remains loaded; plist retained")
        target.unlink(missing_ok=True)
        return 0
    for tool in ("git", "jq", "python3", "gh", "launchctl", "lsof"):
        if not shutil.which(tool):
            raise RuntimeError("missing required tool: " + tool)
    local = Path(__file__).resolve().parents[1]
    stable = home / ".claude/skills-worktree/.claude/scripts"
    scripts = stable if all((stable / p).is_file() for p in
                            ("workspace-sweep.sh", "lib/workspace_sweep.py",
                             "stale-cleanup.sh", "lib/stale-cleanup-finished.py")) else local
    runner = scripts / "workspace-sweep.sh"
    if not runner.is_file():
        raise RuntimeError("workspace-sweep runner missing")
    template = scripts / (LABEL + ".plist")
    config = plistlib.loads(template.read_bytes())
    dirs = [str(Path(shutil.which(t)).parent) for t in ("git", "jq", "python3", "gh", "lsof")]
    dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    config.update(ProgramArguments=["/bin/bash", str(runner), "--trigger", "daily", "--configured"],
                  EnvironmentVariables={"PATH": ":".join(dict.fromkeys(dirs))},
                  StandardOutPath=str(home / ".claude/logs/workspace-sweep.out.log"),
                  StandardErrorPath=str(home / ".claude/logs/workspace-sweep.err.log"),
                  StartCalendarInterval={"Hour": args.hour, "Minute": 0})
    rendered = plistlib.dumps(config)
    # Parsing/escaping is done by plistlib, including paths containing & or <.
    plistlib.loads(rendered)
    previous = target.read_bytes() if target.exists() else None
    if previous and not args.force:
        old = plistlib.loads(previous).get("ProgramArguments", [])
        if old != config["ProgramArguments"]:
            raise RuntimeError("installed job points elsewhere; pass --force to replace it")
    if args.dry_run:
        sys.stdout.write(rendered.decode())
        print("# Manual command: " + shlex.join(config["ProgramArguments"]))
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    (home / ".claude/logs").mkdir(parents=True, exist_ok=True)
    if previous:
        publish(target.with_suffix(".plist.bak"), previous)
    publish(target, rendered)
    if shutil.which("plutil"):
        result = subprocess.run(["plutil", "-lint", str(target)], capture_output=True, timeout=10)
        if result.returncode:
            if previous:
                publish(target, previous)
            else:
                target.unlink()
            raise RuntimeError("rendered plist failed plutil validation")
    launch("bootout", service, check=False)
    try:
        launch("bootstrap", domain, str(target))
    except (RuntimeError, OSError, subprocess.SubprocessError):
        if previous:
            publish(target, previous)
            launch("bootstrap", domain, str(target), check=False)
        else:
            target.unlink()
        raise
    launch("enable", service)
    launch("kickstart", service)
    launch("list", LABEL)
    print("Installed " + LABEL)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print("workspace-sweep installer: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
