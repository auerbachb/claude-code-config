#!/usr/bin/env python3
"""Unit tests for .claude/hooks/config-protection.py."""

import importlib.util
import pathlib
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG_PROTECTION_PATH = REPO_ROOT / ".claude" / "hooks" / "config-protection.py"

spec = importlib.util.spec_from_file_location("config_protection", CONFIG_PROTECTION_PATH)
config_protection = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(config_protection)


class ConfigProtectionPathTests(unittest.TestCase):
    def test_is_protected_basename(self) -> None:
        protected = [
            '.coderabbit.yaml',
            'path/to/.coderabbit.yaml',
            'biome.json',
            '.shellcheckrc',
        ]
        for path in protected:
            with self.subTest(path=path):
                self.assertTrue(config_protection.is_protected_path(path))

    def test_is_protected_relative(self) -> None:
        protected = [
            '.github/scripts/rule-lint.sh',
            'foo/.github/scripts/rule-lint.sh',
            '.claude/rules/.budget-soft-cap',
        ]
        for path in protected:
            with self.subTest(path=path):
                self.assertTrue(config_protection.is_protected_path(path))

    def test_ignores_unrelated_paths(self) -> None:
        ignored = ['', 'README.md', 'setup.sh', '.env', 'CLAUDE.md']
        for path in ignored:
            with self.subTest(path=path):
                self.assertFalse(config_protection.is_protected_path(path))


class ConfigProtectionEditTests(unittest.TestCase):
    def test_allows_create_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            self.assertFalse(config_protection.should_block_edit(str(target)))

    def test_blocks_edit_when_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            self.assertTrue(config_protection.should_block_edit(str(target)))


class ConfigProtectionBashTests(unittest.TestCase):
    def test_bash_blocks_mutation_of_existing_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            target.write_text('existing: true\n', encoding='utf-8')
            cmd = f"sed -i 's/x/y/' {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertEqual(blocked, str(target))

    def test_bash_allows_create_of_missing_protected_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / '.coderabbit.yaml'
            cmd = f"printf 'new' > {target}"
            blocked = config_protection.bash_targets_protected(cmd)
            self.assertIsNone(blocked)


if __name__ == '__main__':
    unittest.main()
