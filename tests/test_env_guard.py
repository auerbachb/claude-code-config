#!/usr/bin/env python3
"""Unit tests for .claude/hooks/env-guard.py."""

import importlib.util
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
ENV_GUARD_PATH = REPO_ROOT / ".claude" / "hooks" / "env-guard.py"

spec = importlib.util.spec_from_file_location("env_guard", ENV_GUARD_PATH)
env_guard = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(env_guard)


class EnvGuardPathTests(unittest.TestCase):
    def test_is_env_path_allows_template_suffixes(self) -> None:
        allowed = [
            ".env.example",
            ".env.sample",
            ".env.template",
            "path/to/.env.example",
            "path/to/.env.sample",
            "path/to/.env.template",
            ".env.EXAMPLE",
            "path/to/.env.SAMPLE",
            "'path/to/.env.TEMPLATE'",
        ]

        for path in allowed:
            with self.subTest(path=path):
                self.assertFalse(env_guard.is_env_path(path))

    def test_is_env_path_blocks_bare_and_non_template_suffixes(self) -> None:
        blocked = [
            ".env",
            ".env.local",
            ".env.production",
            ".env.test",
            ".env.ci",
            ".env.development",
            "path/to/.env",
            "path/to/.env.local",
            "path/to/.env.production",
            "path/to/.env.test",
            "path/to/.env.ci",
            "path/to/.env.development",
        ]

        for path in blocked:
            with self.subTest(path=path):
                self.assertTrue(env_guard.is_env_path(path))

    def test_is_env_path_ignores_non_dotenv_filenames(self) -> None:
        ignored = [
            "",
            "environment.ts",
            "env-config.json",
            "rails_env",
            "my.env.backup",
            "path/to/.env.example/child",
        ]

        for path in ignored:
            with self.subTest(path=path):
                self.assertFalse(env_guard.is_env_path(path))


class EnvGuardBashTests(unittest.TestCase):
    def test_bash_targets_env_allows_template_suffixes(self) -> None:
        allowed = [
            "touch .env.example",
            "rm path/to/.env.sample",
            "printf x > .env.template",
            "printf x > path/to/.env.EXAMPLE",
        ]

        for command in allowed:
            with self.subTest(command=command):
                self.assertFalse(env_guard.bash_targets_env(command))

    def test_bash_targets_env_blocks_dotenv_and_non_template_suffixes(self) -> None:
        blocked = [
            "touch .env",
            "rm path/to/.env.local",
            "printf x > .env.production",
            "printf x > path/to/.env.test",
            "cp source path/to/.env.ci",
            "mv source path/to/.env.development",
        ]

        for command in blocked:
            with self.subTest(command=command):
                self.assertTrue(env_guard.bash_targets_env(command))


if __name__ == "__main__":
    unittest.main()
