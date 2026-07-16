#!/usr/bin/env python3
"""Unit tests for .claude/scripts/cr-plan-filter.py (issue #541).

Fixtures are verbatim CodeRabbit comment bodies captured from this repo:
  - issue #540/#541 issue-enrichment boilerplate (the false positive)
  - issue #452 "## Coding Plan" reply (a real plan, excerpted)
  - issue #541 "plan generation is already in progress" warning
"""

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
FILTER_PATH = REPO_ROOT / ".claude" / "scripts" / "cr-plan-filter.py"

spec = importlib.util.spec_from_file_location("cr_plan_filter", FILTER_PATH)
cr_plan_filter = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(cr_plan_filter)


# Verbatim from issue #540 (2026-07-15): CodeRabbit issue-enrichment beta
# response to `@coderabbitai plan` — >200 chars, zero plan content.
ENRICHMENT_540 = """<!-- This is an auto-generated issue plan by CodeRabbit -->
<details>
<summary>🔗 Related PRs</summary>

auerbachb/claude-code-config#210 - refactor: condense CLAUDE.md via deduplication into rule files [merged]
auerbachb/claude-code-config#404 - Integrate CodeAnt merge gate + Graphite wiring docs (`#367`) [merged]
auerbachb/claude-code-config#406 - CR rate limits: batching, session-state tracking, cr-review-hourly.sh (`#28`) [merged]
auerbachb/claude-code-config#441 - feat: complexity-gated AI review triggers after CR rounds (`#362`) [closed]
auerbachb/claude-code-config#453 - feat(wrap): autonomous merge-gate recovery via /fixpr delegation (`#452`) [closed]
</details>

---
<details>
<summary>📝 Issue Planner</summary>

<sub>Check the box below or use the `@coderabbitai plan` command to generate an implementation plan and prompts that you can use with your favorite coding assistant.</sub>

- [ ] <!-- {"checkboxId": "8d4f2b9c-3e1a-4f7c-a9b2-d5e8f1c4a7b9"} --> Create Plan
</details>


---
<details>
<summary> 🧪 Issue enrichment is currently in open beta.</summary>


You can configure auto-planning by selecting labels in the issue_enrichment configuration.

To disable automatic issue enrichment, add the following to your `.coderabbit.yaml`:
```yaml
issue_enrichment:
  auto_enrich:
    enabled: false
```
</details>

💬 Have feedback or questions? Drop into our [discord](https://discord.gg/coderabbit)!"""


# Verbatim from issue #541: reply to a second `@coderabbitai plan`.
WARNING_IN_PROGRESS = """<!-- This is an auto-generated reply by CodeRabbit -->
> [!WARNING]
> A plan generation is already in progress. Please wait for it to complete before requesting a new plan."""


# Verbatim excerpt (head, details balanced) of the real plan on issue #452.
REAL_PLAN_452 = """<!-- This is an auto-generated reply by CodeRabbit -->
## Coding Plan

### Summary

- Transform `/wrap` Phase 2 into an autonomous recovery loop that wraps `merge-gate.sh` with blocker classification, recovery dispatch, and iteration control
- Use direct script calls (`dismiss-stale-bot-changes.sh`, `resolve-review-threads.sh`, trigger comments) for stateless cleanup, reserving `/fixpr` delegation for rebase and CI fixes requiring code changes
- Convert Phase 1 from a hard-stop gate to a signal that feeds Phase 2's recovery dispatcher, avoiding double-handling of the same findings
- Enforce safety invariants (never dismiss human reviews, never resolve unverified threads) with explicit guards throughout the loop

<details>
<summary><b>Design Choices</b></summary>

<details>
<summary><b>Design Choice 1: /fixpr invocation strategy for different recovery actions</b></summary>



**Options Considered:**
1. Always delegate everything to `/fixpr` for consistency (simpler dispatch logic, but more overhead)
2. Direct script calls for dismissals/thread-resolution/triggers; `/fixpr` only for rebase and CI fixes (per ticket recommendation)
3. Direct script calls for everything, never invoke `/fixpr` (loses code-fix capability)

**Chosen Option:** 2

**Rationale:** Direct scripts for stateless cleanup (dismiss, resolve, trigger comment), `/fixpr` delegation for operations requiring code analysis or git operations (rebase, CI fixes). This matches the ticket's explicit recommendation and minimizes token overhead.

</details>

</details>

<b>💡 User Tips</b>

Regenerate the plan with different choices with `@coderabbitai <feedback>`.


## Implementation Steps


### Phase 1: Recovery Loop Infrastructure

Add the core recovery loop structure to `/wrap` Phase 2, including iteration control, heartbeat logging, blocker classification, and termination conditions."""


ACK_COMMENT = (
    "Actions performed — Full review triggered. "
    + "Reviewing every changed file against the configured instructions now. " * 4
)


def cr(body):
    return {"author": {"login": "coderabbitai"}, "body": body}


class IsSubstantiveTests(unittest.TestCase):
    def test_enrichment_540_rejected(self) -> None:
        self.assertFalse(cr_plan_filter.is_substantive(ENRICHMENT_540))

    def test_enrichment_strips_to_nearly_nothing(self) -> None:
        core = cr_plan_filter.stripped_core(ENRICHMENT_540)
        self.assertLess(len(core), 200)

    def test_enrichment_with_checked_checkbox_rejected(self) -> None:
        checked = ENRICHMENT_540.replace("- [ ]", "- [x]")
        self.assertFalse(cr_plan_filter.is_substantive(checked))

    def test_enrichment_with_bold_summary_rejected(self) -> None:
        bold = ENRICHMENT_540.replace(
            "<summary>📝 Issue Planner</summary>",
            "<summary><b>📝 Issue Planner</b></summary>",
        )
        self.assertNotEqual(bold, ENRICHMENT_540)
        self.assertFalse(cr_plan_filter.is_substantive(bold))

    def test_enrichment_with_markdown_bold_summary_rejected(self) -> None:
        bold = ENRICHMENT_540.replace(
            "<summary>🔗 Related PRs</summary>",
            "<summary>**Related PRs**</summary>",
        )
        self.assertNotEqual(bold, ENRICHMENT_540)
        self.assertFalse(cr_plan_filter.is_substantive(bold))

    def test_enrichment_with_details_attributes_rejected(self) -> None:
        with_attrs = ENRICHMENT_540.replace("<details>", '<details open dir="auto">')
        self.assertFalse(cr_plan_filter.is_substantive(with_attrs))

    def test_warning_in_progress_rejected(self) -> None:
        self.assertFalse(cr_plan_filter.is_substantive(WARNING_IN_PROGRESS))

    def test_long_warning_variant_rejected_by_structure(self) -> None:
        # Even inflated past the length threshold, prose without headings or
        # numbered steps must not count as a plan.
        long_warning = WARNING_IN_PROGRESS + (
            "\n> Please wait for the current run to finish before asking again." * 10
        )
        self.assertFalse(cr_plan_filter.is_substantive(long_warning))

    def test_real_plan_accepted(self) -> None:
        self.assertTrue(cr_plan_filter.is_substantive(REAL_PLAN_452))

    def test_ack_rejected_regardless_of_length(self) -> None:
        self.assertGreater(len(ACK_COMMENT), 200)
        self.assertFalse(cr_plan_filter.is_substantive(ACK_COMMENT))

    def test_short_comment_rejected(self) -> None:
        self.assertFalse(cr_plan_filter.is_substantive("## Plan\n1. Too short."))

    def test_non_noise_details_survive_stripping(self) -> None:
        # A non-noise <details> block followed by a noise block: the tempered
        # summary match must strip only the noise block.
        body = (
            "<details>\n<summary>Walkthrough</summary>\n"
            "KEEP_MARKER " + "step detail content. " * 20 + "\n</details>\n"
            "<details>\n<summary>🔗 Related PRs</summary>\nNOISE_MARKER\n</details>\n"
            "## Plan\n1. Do the thing\n"
        )
        core = cr_plan_filter.stripped_core(body)
        self.assertIn("KEEP_MARKER", core)
        self.assertNotIn("NOISE_MARKER", core)
        self.assertTrue(cr_plan_filter.is_substantive(body))

    def test_plan_wrapped_in_details_accepted(self) -> None:
        body = (
            "<details>\n<summary>Full plan</summary>\n\n"
            "### Steps\n" + "1. A concrete implementation step with detail.\n" * 12
            + "</details>"
        )
        self.assertTrue(cr_plan_filter.is_substantive(body))

    def test_enrichment_marker_rejects_even_with_heading_and_length(self) -> None:
        # If CodeRabbit rewords its summaries or adds headings to the
        # enrichment layout, the leading machine marker must still reject it.
        body = (
            "<!-- This is an auto-generated issue plan by CodeRabbit -->\n"
            "## Suggested labels\n\n"
            + "Some enrichment prose that is not a plan but is quite long. " * 8
        )
        self.assertFalse(cr_plan_filter.is_substantive(body))

    def test_real_plan_quoting_enrichment_marker_accepted(self) -> None:
        # Observed on issue #541: the real plan's prose quotes the enrichment
        # marker. Marker rejection is anchored to the start of the body only.
        body = REAL_PLAN_452 + (
            "\n\n### Note\n1. Strip `<!-- This is an auto-generated issue plan "
            "by CodeRabbit -->` markers before measuring substance.\n"
        )
        self.assertTrue(cr_plan_filter.is_substantive(body))

    def test_unclosed_noise_block_fails_keep_not_over_strip(self) -> None:
        # A truncated enrichment block (no </details>) must not send the
        # regex scanning to end-of-input or swallow trailing content; the
        # block simply stays, and the structure gate still decides.
        body = (
            "<details>\n<summary>🔗 Related PRs</summary>\n"
            + "owner/repo#1 - unclosed noise line\n" * 20
        )
        core = cr_plan_filter.stripped_core(body)
        self.assertIn("unclosed noise line", core)
        self.assertFalse(cr_plan_filter.is_substantive(body))

    def test_nested_details_inside_noise_block_fails_keep(self) -> None:
        # A noise-named block that NESTS another details block doesn't match
        # the strip regex (fail-keep) — content after the inner closer must
        # never be swallowed.
        body = (
            "<details>\n<summary>Related PRs affected</summary>\n"
            "outer prose\n"
            "<details>\n<summary>inner</summary>\ninner prose\n</details>\n"
            "TRAILING_MARKER\n"
            "</details>\n\n"
            "## Plan\n" + "1. Real step with plenty of detail here.\n" * 8
        )
        core = cr_plan_filter.stripped_core(body)
        self.assertIn("TRAILING_MARKER", core)
        self.assertTrue(cr_plan_filter.is_substantive(body))


class LatestPlanTests(unittest.TestCase):
    def test_no_comments(self) -> None:
        self.assertIsNone(cr_plan_filter.latest_plan([]))

    def test_enrichment_only(self) -> None:
        self.assertIsNone(cr_plan_filter.latest_plan([cr(ENRICHMENT_540)]))

    def test_enrichment_then_plan_returns_plan(self) -> None:
        got = cr_plan_filter.latest_plan([cr(ENRICHMENT_540), cr(REAL_PLAN_452)])
        self.assertEqual(got, REAL_PLAN_452)

    def test_plan_then_enrichment_still_returns_plan(self) -> None:
        got = cr_plan_filter.latest_plan([cr(REAL_PLAN_452), cr(ENRICHMENT_540)])
        self.assertEqual(got, REAL_PLAN_452)

    def test_two_plans_returns_latest(self) -> None:
        second = REAL_PLAN_452 + "\n\n### Addendum\n1. Revised step after feedback."
        got = cr_plan_filter.latest_plan([cr(REAL_PLAN_452), cr(second)])
        self.assertEqual(got, second)

    def test_wrong_author_ignored(self) -> None:
        comments = [{"author": {"login": "some-human"}, "body": REAL_PLAN_452}]
        self.assertIsNone(cr_plan_filter.latest_plan(comments))

    def test_bot_suffixed_author_ignored(self) -> None:
        # Issue comments use the bare login; `coderabbitai[bot]` is the PR-side
        # identity and must not match (preserves the pre-#541 contract).
        comments = [{"author": {"login": "coderabbitai[bot]"}, "body": REAL_PLAN_452}]
        self.assertIsNone(cr_plan_filter.latest_plan(comments))

    def test_missing_fields_are_safe(self) -> None:
        comments = [
            {},
            {"author": None, "body": REAL_PLAN_452},
            {"author": {"login": "coderabbitai"}},
            {"author": {"login": "coderabbitai"}, "body": None},
            "not-a-dict",
        ]
        self.assertIsNone(cr_plan_filter.latest_plan(comments))

    def test_stdin_oserror_exits_two_not_traceback(self) -> None:
        # Regression: the OSError handler must not assume argv[1] exists.
        class _Boom:
            def read(self, *args, **kwargs):
                raise OSError("stdin went away")

        real_stdin = sys.stdin
        cr_plan_filter.sys.stdin = _Boom()
        try:
            rc = cr_plan_filter.main(["cr-plan-filter.py"])
        finally:
            cr_plan_filter.sys.stdin = real_stdin
        self.assertEqual(rc, 2)


class CliTests(unittest.TestCase):
    def run_filter(self, stdin_text: str) -> "subprocess.CompletedProcess[str]":
        return subprocess.run(
            [sys.executable, str(FILTER_PATH)],
            input=stdin_text,
            capture_output=True,
            text=True,
        )

    def test_plan_printed_exit_zero(self) -> None:
        payload = json.dumps({"comments": [cr(ENRICHMENT_540), cr(REAL_PLAN_452)]})
        proc = self.run_filter(payload)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, REAL_PLAN_452 + "\n")

    def test_no_plan_empty_stdout_exit_zero(self) -> None:
        payload = json.dumps({"comments": [cr(ENRICHMENT_540), cr(WARNING_IN_PROGRESS)]})
        proc = self.run_filter(payload)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")

    def test_missing_comments_key_exit_zero(self) -> None:
        proc = self.run_filter("{}")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")

    def test_malformed_json_exit_two(self) -> None:
        proc = self.run_filter("{not json")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("invalid JSON", proc.stderr)

    def test_non_object_input_exit_two(self) -> None:
        proc = self.run_filter("[]")
        self.assertEqual(proc.returncode, 2)

    def test_non_array_comments_exit_two(self) -> None:
        proc = self.run_filter('{"comments": 42}')
        self.assertEqual(proc.returncode, 2)

    def test_argv_path_plan_printed_exit_zero(self) -> None:
        # cr-plan.sh stages gh output to a temp file and passes its path.
        payload = json.dumps({"comments": [cr(ENRICHMENT_540), cr(REAL_PLAN_452)]})
        with tempfile.TemporaryDirectory() as tmp:
            json_path = pathlib.Path(tmp) / "comments.json"
            json_path.write_text(payload, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(FILTER_PATH), str(json_path)],
                capture_output=True,
                text=True,
            )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, REAL_PLAN_452 + "\n")

    def test_argv_path_unreadable_exit_two(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(FILTER_PATH), "/nonexistent/comments.json"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("cannot read", proc.stderr)

    def test_extra_args_exit_two(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(FILTER_PATH), "a.json", "b.json"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("usage", proc.stderr)


if __name__ == "__main__":
    unittest.main()
