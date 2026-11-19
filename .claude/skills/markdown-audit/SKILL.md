---
name: markdown-audit
description: Use when Markdown feels bloated, duplicated or contradictory — "what can we cut", "which skills overlap", "markdown-audit". Audits a file, folder or the repo bottom-up at seven levels, sentence to repo; reports located cut/merge/move/keep findings and words removable. Read-only; files only what you accept.
argument-hint: "[file | folder] [--from <level>] [--stop-at <level>] [--no-file]"
---

# markdown-audit — does each piece of writing earn its place?

Reads Markdown from the smallest unit up and asks, at each size, whether the
text earns its place. One level at a time, bottom up, so a redundant sentence
inside a good paragraph and a duplicated section made of good sentences are
both found.

> **ADVISORY AND READ-ONLY — NON-NEGOTIABLE.** This skill never edits, moves,
> stages or commits an audited file, even when a fix is obvious. Its output is a
> report stored outside the checkout and, only for findings the owner accepts,
> issues filed through `/issue-maker`. Edits happen later through the normal
> issue → branch → PR flow. A run that changes the checkout is a failed run.

**Feeds, does not replace.** The weekly rule-slimming pass (#796), the skill
usage audit and the doc lints keep running unchanged. This skill hands them
located evidence; it never gates or skips them.

## Levels

Bottom up: `1 sentence`, `2 block`, `3 section`, `4 page` (50 lines or one
top-level heading's content, whichever is smaller), `5 document`, `6 group`
(sibling files), `7 repo` (every Markdown file). Sibling group: every Markdown
file under `.claude/skills/` is one group; any other file's group is its own
folder. Each level's question, unit, evidence, allowed actions and `keep` rules
live in `references/levels.md`; read it only when building agent briefs
(Step 3).

## Invocation

| Invocation | Levels run |
|------------|------------|
| `/markdown-audit path/to/file.md` | 1–7 |
| `/markdown-audit path/to/folder` | 1–7 |
| `/markdown-audit` (or the checkout root) | 5–7 — sentence-to-page review repo-wide is expensive |
| `… --stop-at <level>` | caps the run; nothing above it is reported |
| `… --from <level>` | lowers or raises the start (`--from 1` for a full repo-wide run) |
| `… --no-file` | report only; skip the filing gate |

Naming a file or folder is the request the issue asked for before levels 1–4
run; a repo-wide run stays at 5–7 unless `--from` asks for more. That reading
is an owner-reversible decision recorded in the PR that added this skill.

A level is a number `1`–`7` or a name from the table. `--from` above
`--stop-at`, an unknown level, or a repo-wide `--stop-at` below 5 without
`--from` stops with an error before anything runs.

## Step 1 — Snapshot, level range, read-only baseline

Set the three variables from the invocation (empty when not given), then run
this block from the directory the user is working in. It resolves the helper,
fixes the snapshot, records the read-only baseline, and builds only the inputs
the level range needs.

<!-- test-anchor: markdown-audit-snapshot -->
```bash
MDA_TARGET="${MDA_TARGET-}"   # file or folder from the invocation; empty = whole repo
MDA_FROM="${MDA_FROM-}"       # --from value, or empty
MDA_STOP="${MDA_STOP-}"       # --stop-at value, or empty
MDA_TOP=$(git rev-parse --show-toplevel) || { echo "ERROR: not inside a git checkout" >&2; exit 1; }
MDA_TOP=$(cd "$MDA_TOP" && pwd -P) || exit 1
# Installed copies only: never run a helper the audited checkout supplies.
MDAUDIT=""
for mda_candidate in \
  "${HOME:+$HOME/.claude/skills-worktree/.claude/skills/markdown-audit/mdaudit.py}" \
  "${HOME:+$HOME/.claude/skills/markdown-audit/mdaudit.py}"; do
  if [[ -n "$mda_candidate" && -f "$mda_candidate" ]]; then MDAUDIT="$mda_candidate"; break; fi
done
[[ -n "$MDAUDIT" ]] || { echo "ERROR: mdaudit.py not found (checked both installed paths; the checkout's own copy is never run) — markdown audit unavailable" >&2; exit 1; }
mda_tmp_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P) || { echo "ERROR: TMPDIR is not a directory" >&2; exit 1; }
case "$mda_tmp_parent/" in
  "$MDA_TOP"/*) echo "ERROR: TMPDIR resolves inside the checkout ($mda_tmp_parent); set TMPDIR elsewhere" >&2; exit 1 ;;
esac
MDA_RUN=$(mktemp -d "$mda_tmp_parent/markdown-audit.XXXXXX") || exit 1
echo "MDA_RUN=$MDA_RUN"
mda_inv_args=()
[[ -n "$MDA_TARGET" ]] && mda_inv_args+=(--target "$MDA_TARGET")
python3 "$MDAUDIT" inventory ${mda_inv_args[@]+"${mda_inv_args[@]}"} > "$MDA_RUN/snapshot.json" || exit 1
MDA_KIND=$(jq -r '.target_kind' "$MDA_RUN/snapshot.json") || exit 1
mda_lvl_args=(--kind "$MDA_KIND")
[[ -n "$MDA_FROM" ]] && mda_lvl_args+=(--from "$MDA_FROM")
[[ -n "$MDA_STOP" ]] && mda_lvl_args+=(--stop-at "$MDA_STOP")
MDA_RANGE=$(python3 "$MDAUDIT" levels "${mda_lvl_args[@]}") || exit 1
MDA_LO=${MDA_RANGE%% *}
MDA_HI=${MDA_RANGE##* }
python3 "$MDAUDIT" fingerprint --snapshot "$MDA_RUN/snapshot.json" > "$MDA_RUN/before.json" || exit 1
# From here a failure still runs the read-only check before stopping.
mda_fail() {
  echo "ERROR: $1" >&2
  python3 "$MDAUDIT" verify-unchanged --snapshot "$MDA_RUN/snapshot.json" --before "$MDA_RUN/before.json"
  exit 1
}
[[ "$(jq -r .head "$MDA_RUN/snapshot.json")" == "$(jq -r .head "$MDA_RUN/before.json")" ]] \
  || mda_fail "HEAD moved between inventory and baseline; restart the audit"
if (( MDA_LO <= 5 )); then
  python3 "$MDAUDIT" segment --snapshot "$MDA_RUN/snapshot.json" > "$MDA_RUN/segments.json" || mda_fail "segment failed"
fi
if (( MDA_LO <= 6 && MDA_HI >= 6 )); then
  python3 "$MDAUDIT" pairs --snapshot "$MDA_RUN/snapshot.json" --level 6 > "$MDA_RUN/pairs-6.json" || mda_fail "pairs (level 6) failed"
fi
if (( MDA_HI >= 7 )); then
  python3 "$MDAUDIT" pairs --snapshot "$MDA_RUN/snapshot.json" --level 7 > "$MDA_RUN/pairs-7.json" || mda_fail "pairs (level 7) failed"
fi
printf 'MDAUDIT=%s\nMDA_TOP=%s\nKIND=%s\nLEVELS=%s-%s\nFILES=%s\n' "$MDAUDIT" "$MDA_TOP" \
  "$MDA_KIND" "$MDA_LO" "$MDA_HI" "$(jq '.in_scope | length' "$MDA_RUN/snapshot.json")"
```

Any non-zero exit: print the error line and STOP (after the baseline exists,
the block itself runs `verify-unchanged` first). Keep `MDA_RUN`, `MDAUDIT`,
`MDA_TOP`, `MDA_LO` and `MDA_HI` for the later steps. The run directory is outside the
checkout; nothing in this skill writes inside it.

## Step 2 — Never run a level outside the range

Only levels `MDA_LO`–`MDA_HI` are briefed, judged or reported. Levels 1–5 use
`segments.json`; levels 6–7 use `pairs-6.json` / `pairs-7.json`. A level outside
the range gets no brief, no finding, and no report heading.

## Step 3 — Judgment pass (read-only agents)

Read `references/levels.md` now. Spawn `researcher` agents (read-only: they
cannot edit files or file issues) with an explicit `model`. Each brief is
self-contained: HEAD (`.head` in the snapshot), the files, the unit map or pair
ranges, the levels in range, the rubric excerpt for those levels, and the
output format from `references/levels.md`.

- **Levels 1–5:** one brief per file, or per batch of small files (about 3,000
  words per brief).
- **Levels 6–7:** one brief per batch of about ten candidate pairs; every pair
  gets one verdict and a `"status": "reviewed"` coverage line, with or without
  findings; a pair with findings but no coverage line counts as unreviewed. The `pairs` output is evidence for review, never a
  finding by itself.

Collect agent output into two files in `$MDA_RUN`: `findings.jsonl` (one
finding per line) and `coverage.jsonl` (one line per file-and-level or pair the
agent actually reviewed). An agent that fails or returns nothing leaves its
items unreviewed — never record them as clean.

## Step 4 — Validate, tally, render

<!-- test-anchor: markdown-audit-report -->
```bash
touch "$MDA_RUN/findings.jsonl" "$MDA_RUN/coverage.jsonl"
mda_rep_args=()
for mda_pairs in "$MDA_RUN"/pairs-6.json "$MDA_RUN"/pairs-7.json; do
  [[ -f "$mda_pairs" ]] && mda_rep_args+=(--pairs "$mda_pairs")
done
python3 "$MDAUDIT" report --snapshot "$MDA_RUN/snapshot.json" --findings "$MDA_RUN/findings.jsonl" \
  --coverage "$MDA_RUN/coverage.jsonl" --from "$MDA_LO" --stop-at "$MDA_HI" \
  ${mda_rep_args[@]+"${mda_rep_args[@]}"} > "$MDA_RUN/report.md" || exit 1
python3 "$MDAUDIT" report --snapshot "$MDA_RUN/snapshot.json" --findings "$MDA_RUN/findings.jsonl" \
  --coverage "$MDA_RUN/coverage.jsonl" --from "$MDA_LO" --stop-at "$MDA_HI" --format json \
  ${mda_rep_args[@]+"${mda_rep_args[@]}"} > "$MDA_RUN/report.json" || exit 1
```

`report` drops and lists invalid findings (outside the snapshot, bad line
range, unknown action, merge/move with no target, levels 6–7 with no second
file, multi-line reason) — never repair them by guesswork. It renders the
levels in order, a words-removable table per level and in total (ranges merged
so no line counts twice; moved words are reported separately, not as removed),
coverage with unreviewed items and exclusions, invalid findings, and "What NOT
to change" (the `keep` rows).

## Step 5 — Read-only check, then store

The report is stored only after the checkout is proven unchanged, so a failed
run never leaves an ordinary-looking report behind:

```bash
if ! python3 "$MDAUDIT" verify-unchanged --snapshot "$MDA_RUN/snapshot.json" --before "$MDA_RUN/before.json"; then
  echo "ERROR: checkout changed during the audit; report not stored (left in $MDA_RUN)" >&2; exit 1
fi
MDA_DIR="${HOME:?HOME must be set}/.claude/reports/markdown-audit"
mda_probe="$MDA_DIR"
while [[ ! -d "$mda_probe" ]]; do mda_probe=$(dirname "$mda_probe"); done
case "$(cd "$mda_probe" && pwd -P)/" in
  "$MDA_TOP"/*) echo "ERROR: report directory resolves inside the checkout; report not written" >&2; exit 1 ;;
esac
mkdir -p "$MDA_DIR" || exit 1
case "$(cd "$MDA_DIR" && pwd -P)/" in
  "$MDA_TOP"/*) echo "ERROR: report directory resolves inside the checkout; report not written" >&2; exit 1 ;;
esac
MDA_OUT="$MDA_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
# Write a temporary file, then publish it with a hard link, which never
# replaces an existing report; a failed or partial write leaves no report.
mda_tmp=$(mktemp "$MDA_DIR/.partial.XXXXXX") || { echo "ERROR: cannot create a file in $MDA_DIR" >&2; exit 1; }
if ! cat "$MDA_RUN/report.md" > "$mda_tmp"; then
  rm -f "$mda_tmp"; echo "ERROR: writing the report failed; report not stored" >&2; exit 1
fi
if ! ln "$mda_tmp" "$MDA_OUT"; then
  rm -f "$mda_tmp"; echo "ERROR: could not publish $MDA_OUT (path taken or link refused)" >&2; exit 1
fi
rm -f "$mda_tmp"
echo "REPORT=$MDA_OUT"
```

`UNCHANGED` (exit 0) is required. `CHANGED` (exit 1) is a failed run: nothing
is stored, report every listed difference at the top of the summary and file
nothing. The check compares HEAD, `git status`, and every corpus file's
content, so it holds in a checkout that was already dirty. The stored report
never overwrites an earlier one.

## Step 6 — Summary, then the filing gate

Tell the user: findings per level, total words removable, unreviewed counts,
and the report path. Then:

1. Build proposed issues **only from `.findings` in `$MDA_RUN/report.json`** —
   already validated and free of keep conflicts — never from `findings.jsonl`.
   Group the non-`keep` rows that share one fix: all findings in one file, or
   in one file pair. Invalid rows, conflicts, and pair findings whose pair the
   report does not list as reviewed — no `"reviewed"` coverage line, or a pair
   absent from the candidate list (`report` lists them apart) — are never
   offered.
2. `--no-file`, or the session is unattended (`human-queue.md`): STOP here.
   Unattended runs record the pending filing question for the operator's return.
3. Otherwise ask once, multi-select, **Skip first**: `"Skip — file nothing"`,
   then one option per proposed issue. **Skip wins** over any other selection;
   silence or a decline files nothing.
4. Invoke `/issue-maker` through the Skill tool with **only the accepted
   groups** (`batch:` when more than one), passing the report path and the
   finding rows as context. Post no comments on existing issues. Its dedup
   pauses and errors reach the owner unchanged.
5. Filing is not consent to execute: decline `/issue-maker`'s offer to start
   work unless the owner explicitly says yes.

## Exit criteria

STOP after the first of: a blocking error in Steps 1–5, the report under
`--no-file` or unattended, or the filing outcome. Once Step 1 has written
`before.json`, every stop — a Step 3 or Step 4 error included — first runs
Step 5's `verify-unchanged` line (storing nothing) and reports its result. A successful run ends with `verify-unchanged`
printing `UNCHANGED`.
