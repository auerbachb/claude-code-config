#!/usr/bin/env python3
"""Unit tests for .claude/hooks/worktree-guard.sh (issue #549).

The guard must evaluate the TARGET file's checkout — not the session cwd —
so writes outside the repo (session scratchpad, ~/.claude memory) are never
blocked, while writes into a claude-code-config `main` checkout are denied
regardless of where the session cwd sits.
"""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
HOOK_PATH = REPO_ROOT / ".claude" / "hooks" / "worktree-guard.sh"


def run_hook(stdin_text: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(HOOK_PATH)],
        input=stdin_text,
        capture_output=True,
        text=True,
        timeout=30,
    )


def hook_decision(payload: dict) -> str:
    """Return 'deny' or 'allow' for a hook-input payload.

    Empty stdout means the hook made no decision, which the framework
    treats as allow.
    """
    proc = run_hook(json.dumps(payload))
    out = proc.stdout.strip()
    if not out:
        return "allow"
    data = json.loads(out)
    return data["hookSpecificOutput"]["permissionDecision"]


def deny_reason(payload: dict) -> str:
    proc = run_hook(json.dumps(payload))
    data = json.loads(proc.stdout.strip())
    return data["hookSpecificOutput"]["permissionDecisionReason"]


def write_payload(cwd, file_path, tool: str = "Write") -> dict:
    return {
        "tool_name": tool,
        "cwd": str(cwd),
        "tool_input": {"file_path": str(file_path)},
    }


class WorktreeGuardTests(unittest.TestCase):
    """Fixture layout (all under one temp dir, physical paths):

    base/
      claude-code-config/            git repo on `main` (one commit)
        .claude/worktrees/wt/        linked worktree on `issue-test`
      feature/claude-code-config/    git repo on `issue-x` (never main)
      other-config/                  git repo on `main`, non-matching name
      outside/scratchpad/            plain directory, no repo
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.base = pathlib.Path(tempfile.mkdtemp()).resolve()

        cls.repo = cls.base / "claude-code-config"
        cls._init_repo(cls.repo, branch="main")

        cls.worktree = cls.repo / ".claude" / "worktrees" / "wt"
        cls.worktree.parent.mkdir(parents=True)
        cls._git(cls.repo, "worktree", "add", str(cls.worktree), "-b", "issue-test")

        cls.feature_repo = cls.base / "feature" / "claude-code-config"
        cls._init_repo(cls.feature_repo, branch="issue-x")

        cls.other_repo = cls.base / "other-config"
        cls._init_repo(cls.other_repo, branch="main")

        cls.outside = cls.base / "outside" / "scratchpad"
        cls.outside.mkdir(parents=True)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.base, ignore_errors=True)

    @staticmethod
    def _git(cwd: pathlib.Path, *args: str) -> None:
        subprocess.run(
            [
                "git",
                "-c", "user.email=test@example.com",
                "-c", "user.name=Test",
                *args,
            ],
            cwd=str(cwd),
            check=True,
            capture_output=True,
        )

    @classmethod
    def _init_repo(cls, path: pathlib.Path, branch: str) -> None:
        path.mkdir(parents=True)
        cls._git(path, "init", "-q", "-b", branch)
        (path / "README.md").write_text("fixture\n", encoding="utf-8")
        cls._git(path, "add", "README.md")
        cls._git(path, "commit", "-q", "-m", "init")

    # --- The issue #549 regressions: targets OUTSIDE the repo must pass ---

    def test_allows_target_outside_repo_when_cwd_on_main(self) -> None:
        payload = write_payload(self.repo, self.outside / "notes.md")
        self.assertEqual(hook_decision(payload), "allow")

    def test_allows_target_in_nonexistent_dirs_outside_repo(self) -> None:
        # Mirrors the ~/.claude/projects/<slug>/memory/ case: deep path whose
        # directories do not exist yet — the ancestor walk must land outside
        # any repo and allow.
        target = self.base / "home" / ".claude" / "projects" / "x" / "memory" / "m.md"
        payload = write_payload(self.repo, target)
        self.assertEqual(hook_decision(payload), "allow")

    # --- Writes into the main checkout still deny ---

    def test_denies_absolute_target_inside_main_checkout(self) -> None:
        payload = write_payload(self.repo, self.repo / "newfile.md")
        self.assertEqual(hook_decision(payload), "deny")
        reason = deny_reason(payload)
        self.assertIn("BLOCKED", reason)
        self.assertIn(str(self.repo / "newfile.md"), reason)

    def test_denies_relative_target_resolving_inside_main_checkout(self) -> None:
        payload = write_payload(self.repo, "sub/newfile.md")
        self.assertEqual(hook_decision(payload), "deny")

    def test_denies_target_under_nonexistent_dirs_inside_main_checkout(self) -> None:
        payload = write_payload(self.repo, self.repo / "a" / "b" / "c" / "new.md")
        self.assertEqual(hook_decision(payload), "deny")

    def test_denies_edit_tool_inside_main_checkout(self) -> None:
        payload = write_payload(self.repo, self.repo / "README.md", tool="Edit")
        self.assertEqual(hook_decision(payload), "deny")

    def test_denies_symlink_resolving_into_main_checkout(self) -> None:
        link = self.outside / "link.md"
        if not link.is_symlink():
            os.symlink(self.repo / "README.md", link)
        payload = write_payload(self.outside, link)
        self.assertEqual(hook_decision(payload), "deny")

    def test_denies_camelcase_tool_input_inside_main_checkout(self) -> None:
        payload = {
            "tool_name": "Write",
            "cwd": str(self.outside),
            "toolInput": {"file_path": str(self.repo / "newfile.md")},
        }
        self.assertEqual(hook_decision(payload), "deny")

    # --- The target's checkout governs, not the cwd's ---

    def test_allows_target_in_feature_worktree_when_cwd_on_main(self) -> None:
        payload = write_payload(self.repo, self.worktree / "wip.md")
        self.assertEqual(hook_decision(payload), "allow")

    def test_denies_target_in_main_checkout_when_cwd_in_worktree(self) -> None:
        payload = write_payload(self.worktree, self.repo / "drift.md")
        self.assertEqual(hook_decision(payload), "deny")

    def test_allows_repo_checked_out_on_feature_branch(self) -> None:
        payload = write_payload(self.feature_repo, self.feature_repo / "f.md")
        self.assertEqual(hook_decision(payload), "allow")

    def test_allows_differently_named_repo_on_main(self) -> None:
        payload = write_payload(self.other_repo, self.other_repo / "f.md")
        self.assertEqual(hook_decision(payload), "allow")

    # --- NotebookEdit uses notebook_path ---

    def test_notebook_edit_denies_inside_main_checkout(self) -> None:
        payload = {
            "tool_name": "NotebookEdit",
            "cwd": str(self.outside),
            "tool_input": {"notebook_path": str(self.repo / "nb.ipynb")},
        }
        self.assertEqual(hook_decision(payload), "deny")

    def test_notebook_edit_allows_outside_repo(self) -> None:
        payload = {
            "tool_name": "NotebookEdit",
            "cwd": str(self.repo),
            "tool_input": {"notebook_path": str(self.outside / "nb.ipynb")},
        }
        self.assertEqual(hook_decision(payload), "allow")

    # --- Guard rails: tool filter, legacy fallback, fail-open ---

    def test_ignores_non_write_tools(self) -> None:
        payload = write_payload(self.repo, self.repo / "newfile.md", tool="Bash")
        self.assertEqual(hook_decision(payload), "allow")

    def test_missing_file_path_falls_back_to_cwd_deny(self) -> None:
        payload = {"tool_name": "Write", "cwd": str(self.repo), "tool_input": {}}
        self.assertEqual(hook_decision(payload), "deny")

    def test_missing_file_path_with_outside_cwd_allows(self) -> None:
        payload = {"tool_name": "Write", "cwd": str(self.outside), "tool_input": {}}
        self.assertEqual(hook_decision(payload), "allow")

    def test_non_dict_tool_input_falls_back_to_cwd_deny(self) -> None:
        payload = {"tool_name": "Write", "cwd": str(self.repo), "tool_input": "junk"}
        self.assertEqual(hook_decision(payload), "deny")

    def test_non_string_tool_name_allows_without_crash(self) -> None:
        payload = {
            "tool_name": 123,
            "cwd": str(self.repo),
            "tool_input": {"file_path": str(self.repo / "x.md")},
        }
        self.assertEqual(hook_decision(payload), "allow")

    def test_non_string_file_path_falls_back_to_cwd_deny(self) -> None:
        payload = {"tool_name": "Write", "cwd": str(self.repo), "tool_input": {"file_path": 123}}
        self.assertEqual(hook_decision(payload), "deny")

    def test_non_string_cwd_with_absolute_target_denies(self) -> None:
        # Regression (CodeAnt local finding): a non-string cwd used to crash
        # the helper and fail the guard open even for main-checkout targets.
        payload = {
            "tool_name": "Write",
            "cwd": 123,
            "tool_input": {"file_path": str(self.repo / "x.md")},
        }
        self.assertEqual(hook_decision(payload), "deny")

    def test_json_array_stdin_fails_open(self) -> None:
        proc = run_hook("[1, 2, 3]")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")

    def test_malformed_json_fails_open(self) -> None:
        proc = run_hook("this is not json")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")

    def test_empty_stdin_fails_open(self) -> None:
        proc = run_hook("")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
