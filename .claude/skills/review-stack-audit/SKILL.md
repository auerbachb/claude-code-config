---
name: review-stack-audit
description: Use when asking whether the AI review tools still earn what we pay for them — "audit the review stack", "are we still paying for Greptile", "did a cap change", "re-check review tool costs", or the monthly check. Re-measures each tool's billed state, caps, throughput, and unique value, compares against the recorded baseline, and files drift issues. Advisory only — never edits rules.
argument-hint: "[--tick] [--report-only] [--report-to-repo] [--since YYYY-MM-DD] [--days N] [--limit N] [--arm] [--stop]"
---

# review-stack-audit — do the review tools still earn their keep?

Issue #1199 realigned the review chain with what we actually pay for. That was a
snapshot. Subscriptions lapse, caps shrink without notice, pricing moves, and new
tools appear — and none of it announces itself. The last two mismatches (BugBot's
spend cap, CodeAnt's "not subscribed" state) both surfaced as a bad afternoon of
PRs queuing on review rather than as a line item anyone caught early.

This skill is the recurring version of that check.

> **ADVISORY ONLY — NON-NEGOTIABLE.** This skill **never** edits a rule, skill,
> script, or config, and never changes a subscription. Not when the verdict is
> obvious. Its entire output surface is a snapshot, a report, and GitHub issues.
> A human lands any change through the normal issue → branch → PR flow. Billing
> actions are the user's alone — this skill says "this looks like a bill with no
> return", never "cancelled it for you".

**Sibling to `/harness-audit`, not part of it.** That audit asks whether the
harness already does natively what we automate by hand — an internal-redundancy
axis. This one asks whether external spend still buys value. Same cadence, same
advisory posture, same issue-filing discipline; different question.

Resolve the repository locator before either engine runs:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
REPO_ROOT_SH=$(resolve_script repo-root.sh || true)
[[ -n "$REPO_ROOT_SH" ]] || { echo "ERROR: repo-root.sh not found (checked all three paths) — review-stack audit root unavailable" >&2; exit 1; }
```

## The engines

All three are plain scripts, so the judgment in this file stays small and their
behavior is testable offline (`.claude/scripts/tests/review-stack-audit.test.sh`
for the first two, `.claude/scripts/tests/report-path.test.sh` for the third).

| Engine | Where | Job |
|--------|-------|-----|
| `measure.sh` | this skill | What each tool actually did: billed signals, caps, throughput, unique value. No verdicts. |
| `drift.sh` | this skill | Snapshot vs baseline → one finding per divergence, each with a stable dedup marker. Pure function of two JSON files. |
| `report-path.sh` | `.claude/scripts/` — **shared** | Where this run's report goes, guaranteed not to be a path something already occupies (Step 7). Pure function of the target directory. Writes nothing. |

> **`report-path.sh` is not this skill's private engine.** `/harness-audit` writes
> a monthly report on the same cadence and had the identical collision (#1519), so
> the script lives in `.claude/scripts/` and both audits call it with their own
> `--series`. Change it with both callers in mind, and never give `--series` a
> default: a forgotten flag would file one skill's report under the other's name.

Run `--help` on any of them for its full contract. Do not reimplement their
logic here.

---

## Step 0 — Parse mode and resolve context

| Invocation | Meaning |
|------------|---------|
| `/review-stack-audit` | On-demand full run. |
| `/review-stack-audit --tick` | Cheap monthly check, gated on the watermark. Measures and reports; files nothing. |
| `/review-stack-audit --report-only` | Dry run: measure, compare, report. **Files nothing.** |
| `/review-stack-audit --report-to-repo` | Write the report into `.claude/reference/` instead of `~/.claude/`. Refuses outside a non-`main` worktree (Step 7). |
| `/review-stack-audit --arm` | Enable the monthly session-start nudge. |
| `/review-stack-audit --stop` | Disable it. |

`--since` / `--days` / `--limit` pass straight through to `measure.sh` and combine
with any mode. `--arm` and `--stop` are lifecycle modes and mutually exclusive
with the rest.

```bash
REPO_ROOT="$("$REPO_ROOT_SH")"
SKILL_DIR="$REPO_ROOT/.claude/skills/review-stack-audit"
MEASURE="$SKILL_DIR/measure.sh"
DRIFT="$SKILL_DIR/drift.sh"
REPORT_PATH="$REPO_ROOT/.claude/scripts/report-path.sh"   # shared with /harness-audit
DEDUP="$REPO_ROOT/.claude/scripts/issue-dedup.sh"
STATE_DIR="$HOME/.claude/review-stack-audit"
WATERMARK="$STATE_DIR/last-run.json"
MONTH="$(TZ='America/New_York' date +%Y-%m)"
mkdir -p "$STATE_DIR"
```

---

## Step 1 — `--arm` / `--stop` (recurrence lifecycle)

**The recurrence is a session-start check, not a scheduled job.** `CronCreate`
does not outlive the session that armed it (#827), so a monthly audit driven by
one silently never runs — the worst failure for a skill whose job is noticing
silent staleness. What *is* durable is the watermark file, and
`session-scheduling-reconcile.sh` reads it on every session start. Sessions start
far more often than monthly, so a month cannot be missed.

`--arm` and `--stop` toggle `nudge_enabled` in the watermark. Hold the shared
lock and replace atomically — a concurrent `--tick` writing `last_completed_month`
must not be clobbered, and a half-written file must never be what the next
session start reads:

```bash
source "$REPO_ROOT/.claude/scripts/state-lock.sh"
state_lock_acquire "$WATERMARK"
python3 - "$WATERMARK" true <<'PY'      # `false` for --stop
import json, os, sys, tempfile
p, val = sys.argv[1], sys.argv[2] == "true"
d = json.load(open(p)) if os.path.exists(p) else {}
d["nudge_enabled"] = val
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, p)
PY
state_lock_release "$WATERMARK"
```

Arming is idempotent — it sets a boolean, so there is no way to arm twice.
`--arm` then runs one `--tick` so the first month is evaluated immediately;
`--stop` reports and **STOPS**, never auditing. Both leave `last_completed_month`
untouched, so disabling and re-enabling never re-audits a finished month.

---

## Step 2 — `--tick` gating (tick body only)

Skip entirely for every non-`--tick` mode. A tick is pure watermark arithmetic —
there is no job whose survival needs confirming.

| Condition | Action |
|-----------|--------|
| `last_completed_month == $MONTH` | Already audited this month → timestamped heartbeat, **exit**. |
| Otherwise | Run Steps 3–5, report, and set the watermark. **A tick files no issues** (Step 6 is skipped) — it tells you drift exists and hands you the on-demand run that files. |

A tick is cheap: one `measure.sh` call and one `drift.sh` call, no model
judgment. That is why it can afford to run the real comparison rather than just
offering to.

---

## Step 3 — Measure

**Fail closed — a partial measurement is worse than none**, because every
downstream verdict is measured against it. Write to a temp path, validate, and
only then publish:

```bash
TMP_SNAP="$STATE_DIR/.snapshot-$MONTH.json.tmp"
if ! "$MEASURE" ${SINCE:+--since "$SINCE"} ${DAYS:+--days "$DAYS"} ${LIMIT:+--limit "$LIMIT"} --json > "$TMP_SNAP"; then
  rm -f "$TMP_SNAP"
  echo "ERROR: measure.sh failed — aborting rather than auditing a partial window." >&2
  exit 1
fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("tools") else 1)' "$TMP_SNAP" \
  || { rm -f "$TMP_SNAP"; echo "ERROR: snapshot is empty or unparseable — aborting." >&2; exit 1; }
mv "$TMP_SNAP" "$STATE_DIR/snapshot-$MONTH.json"
```

Never fall back to a previous month's snapshot: a stale window would silently
exempt everything that changed since, which is the exact failure this audit
exists to prevent.

**Read `window.truncated` and `unclassified` out of the published snapshot and
carry both into the report.** Truncation means findings counts are floors.
Unclassified entries mean a real cap may be sitting unrecognized — a clean result
is only as trustworthy as the phrase table that produced it.

**Publish the throughput figure.** Issue #1191's concurrent-work cap derives from
review throughput; the report's Throughput section is where that number gets
refreshed, so state it explicitly rather than leaving it inside the JSON.

---

## Step 4 — Resolve the baseline

Resolution order, first hit wins:

1. `.claude/reference/review-stack-baseline.json` — the canonical machine-readable
   record. **This is the path #1199's decision record writes to.**
2. A fenced ```json block tagged `review-stack-baseline` inside the newest
   `.claude/reference/review-stack-audit-*.md` **or**
   `.claude/reference/ai-review-tool-audit-*.md` — newest across both globs.
   Two globs because there are two series: this skill writes the first (Step 7),
   and the hand-run audits that preceded it wrote the second. Dropping either
   makes a baseline block in that series unreachable, and this rung would fail by
   silently never matching rather than by saying anything.
3. Neither → **bootstrap mode.**

**Bootstrap mode is a real outcome, not an error.** Publish the snapshot, file
nothing, and report in one line that a baseline was established and the next run
will compare against it. A first run with nothing to compare against has still
done its job: it created the thing every later run needs. Refusing to run until a
baseline exists would make the skill undeployable in exactly the situation it is
most needed — which is why this departs from CodeRabbit's plan for #1201.

The shipped baseline records what the **2026-06 audit concluded**, deliberately
not what is true today. A baseline pre-loaded with current reality would suppress
the very drift the audit exists to surface.

---

## Step 5 — Compare

```bash
BASELINE=".claude/reference/review-stack-baseline.json"
"$DRIFT" --snapshot "$STATE_DIR/snapshot-$MONTH.json" --baseline "$BASELINE" --json > "$STATE_DIR/drift-$MONTH.json"
RC=$?   # 0 = no drift, 3 = drift found, 1 = input error, 2 = usage
```

`RC=1` is a **hard stop**: a comparison that could not run must never be reported
as "no change". Say what failed and exit.

The five drift codes (D1 demoted-but-leaned-on, D2 paid-but-unused, D3 cap-shrink,
D4 role-vs-reality, D5 unrecorded-tool) are defined in `drift.sh --help`. Do not
re-derive them here or hand-adjust its verdicts; if a verdict looks wrong, the
baseline or the phrase table is wrong, and that is the thing to fix.

---

## Step 6 — File issues

`--report-only` and `--tick` **file nothing** — skip to Step 7.

One issue per drift finding. Dedup is **two layers**, and the order matters:

### Layer 1 — the exact marker (authority)

Every finding carries `marker`, keyed on `(tool, code)` and nothing else, so the
same unresolved drift re-found next month produces a byte-identical string.

- **Title:** `Review stack drift: <tool> — <code>`
- **Body marker:** the finding's `marker` field, e.g.
  `<!-- review-stack-audit: bugbot/D3 -->`
- **Compare the fully-substituted marker by client-side string equality, never
  the `<!-- review-stack-audit:` prefix.** `/harness-audit` learned this on its
  first live run: any issue *documenting* the convention contains the template
  text, and a prefix match reads that as an existing filing for every tool. This
  file contains such text too.

```bash
DEDUP_LIMIT=200
CANDIDATES="$(gh issue list --search "Review stack drift in:title" --state all \
  --limit "$DEDUP_LIMIT" --json number,title,body,state)" || CANDIDATES=""
COUNT="$(jq 'length' <<<"${CANDIDATES:-[]}")"
if [[ -z "$CANDIDATES" ]] || (( COUNT >= DEDUP_LIMIT )); then
  echo "existing_lookup_failed — blocking this filing" >&2
fi
```

**A saturated result set is a failed lookup, not a clean one.** Exactly
`DEDUP_LIMIT` rows means the page was truncated and the issue you needed may be
the one cut. Treat it like a command failure: block the filing, name it, and
carry it into the report's suppressed section.

### Layer 2 — `issue-dedup.sh` (recall)

The marker cannot find an issue a human filed by hand about the same drift. Run
the recall pass over the finding's headline terms before filing:

```bash
CANDS="$("$DEDUP" "<tool> <cap kind or role> review" --exclude "$FILED_THIS_RUN")"; RC=$?
```

Classify per `.claude/reference/autofile-dedup.md`. **Exit ≥ 2 is a degraded
lookup, never "no duplicate"** — it blocks the filing exactly like a saturated
search. A strong match means comment the new evidence onto that issue instead of
filing.

### Same-run registry

Keep a run-scoped set of every `(tool, code)` filed during this run and check it
*before* the repo lookup, then filter this run's issue numbers out of any
repo-side candidates **client-side, after the fetch** — `gh issue list` has no
`--exclude`. Without this, a second finding files a duplicate of an issue created
minutes earlier that the search has not indexed yet.

### Body and never-silent

Use `/issue-maker`'s canonical 6-section body, its label-intersection rule (only
labels that already exist), and its closing-URL convention. Include the marker,
the code, the severity, the observed-vs-expected pair from the finding, and the
window measured. Footer: `_Captured via /review-stack-audit._`

**Every suppressed filing is named in the report** with the issue it deferred to.
A finding that is neither filed nor reported is the outcome this contract exists
to prevent.

---

## Step 7 — Write the snapshot and report

The snapshot is already at `$STATE_DIR/snapshot-$MONTH.json` (Step 3) — dated, so
throughput, spend, and value stay comparable run over run. Never overwrite a
prior month's.

### The report's name — one series, one collision rule

**The series is `review-stack-audit-YYYY-MM.md`, in both destinations.** It is
this skill's own name, and it is the *only* name a report of this skill takes —
there is no second series to choose between and no reason for a report to invent
a deviation (#1345).

> **Not `ai-review-tool-audit-*`.** That series belongs to the hand-run audits
> (2026-04, 2026-06, 2026-08 / #1199). Writing into someone else's slot is what
> collided in 2026-08, forcing PR #1338 to rename its report by hand and explain
> itself in the header. This rule is that explanation, made once and made
> permanent.

**A month can hold more than one report.** When the name is already taken the
report lands under a counter suffix — `review-stack-audit-2026-08-2.md`, then
`-3` — so a second audit in the same month can never overwrite the first. Never
derive this by hand: `report-path.sh` (below) returns a path proven free, and
refuses rather than guessing when it cannot read the target directory.

### Where `$REPORT_DIR` points

**Default is outside the repo:** `REPORT_DIR="$STATE_DIR"`.

> **Why outside.** A tick can run in a session sitting on the root repo on `main`.
> Writing there would put changes on `main` — against `CLAUDE.md` §ALWAYS USE A
> WORKTREE — and trip `dirty-main-guard`. Landing a report *in* the repo stays a
> deliberate, human, PR-shaped act.

`--report-to-repo` sets `REPORT_DIR="$WORKTREE_ROOT/.claude/reference"` instead —
the **current worktree**, and it is valid **only** in a worktree that is not the
root repo, on a branch that is not `main`:

```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [[ "$(git branch --show-current)" != "main" ]] \
  && [[ "$WORKTREE_ROOT" != "$("$REPO_ROOT_SH")" ]]
```

> **Not `$REPO_ROOT`.** `$REPO_ROOT` is `repo-root.sh`'s answer — the root
> checkout, which normally sits on `main`. Writing the report there would put the
> file on `main` and leave it out of the very PR the flag exists to produce,
> which is precisely what the guard above is testing *against*: the third
> condition passes only when the current tree is **not** that path. The
> destination must be the tree the guard just validated, so both derive from the
> same `$WORKTREE_ROOT`. The sibling `/harness-audit` recipe writes to the
> current tree for the same reason.

Refuse otherwise, explain why, and fall back to the default directory. When it
does land in-repo, add the one-line entry under **"Audits and research
(point-in-time)"** in `.claude/reference/README.md`, naming the filename
`report-path.sh` actually returned — suffix included, if it has one.

### Resolve the path, then write

With `$REPORT_DIR` settled, resolve the destination and write through a temp file
in that same directory, the same idiom as Step 3's snapshot, so a half-written
report is never what a reader finds:

```bash
# Resolve, then CLAIM. `set -o noclobber` opens with O_EXCL, so if a simultaneous
# audit took the name between resolving and reserving, the claim fails instead of
# overwriting. Losing that race is not fatal — ask for the next free name and
# claim again. The subshell keeps noclobber out of the rest of the flow.
REPORT=""
for _attempt in 1 2 3 4 5; do
  CANDIDATE="$("$REPORT_PATH" --dir "$REPORT_DIR" --month "$MONTH" --series review-stack-audit)" \
    || { echo "ERROR: report-path.sh could not resolve a free report path in $REPORT_DIR — not writing." >&2; exit 1; }
  if ( set -o noclobber; : > "$CANDIDATE" ) 2>/dev/null; then REPORT="$CANDIDATE"; break; fi
done
[[ -n "$REPORT" ]] \
  || { echo "ERROR: lost the claim race 5 times in $REPORT_DIR — not writing." >&2; exit 1; }

TMP_REPORT="$REPORT_DIR/.$(basename "$REPORT").tmp"

# The claim is an EMPTY placeholder until `mv` lands. If composition dies in
# between, drop it — otherwise the canonical name stays occupied by a blank file
# and every later audit that month is pushed onto -2, -3, … reintroducing the
# confusion #1345 is about. `-s` keeps a real report: after `mv` it is non-empty.
cleanup_report() { rm -f "$TMP_REPORT"; [[ -s "$REPORT" ]] || rm -f "$REPORT"; }
trap cleanup_report EXIT

# ...compose the report into "$TMP_REPORT"...
mv "$TMP_REPORT" "$REPORT"
```

**A non-zero exit from `report-path.sh` is a hard stop, not a cue to fall back to
the base name.** The whole point is that the unverified path is exactly the one
that destroys a prior report.

**The claim is what makes the resolved path yours.** `report-path.sh` creates
nothing, so its answer is only true at the instant it is given; a lock inside it
could not help, because it exits before this flow writes. Claiming with O_EXCL
closes that window at the only layer that can close it. Because `$TMP_REPORT` is
derived from the claimed `$REPORT`, the temp file is unique too, so two audits
cannot collide on it either.

**Two failure modes the claim introduces, and how the block above handles them:**

- **Losing the race must not lose the audit.** A bare hard-stop on a failed claim
  would discard a completed measurement run because another audit happened to be
  writing at that instant. The loop re-resolves instead, so the loser takes the
  next suffix; only five consecutive losses — which would mean something is very
  wrong — abort.
- **A crashed run must not leave the name occupied.** The claim is a zero-byte
  placeholder until `mv` lands, and `report-path.sh` counts any existing file as
  taken. Without cleanup, one failed compose would park an empty file on the
  canonical name and push every later report that month onto a suffix. The `EXIT`
  trap removes the placeholder unless it holds a real report.

Report shape, following the prior audits in this series:

```markdown
# Review stack audit — YYYY-MM

**Issue:** #1201
**Date:** <ET date>
**Window:** <since> → <until> (<N> PRs<, truncated> )
**Baseline:** <path> (<provenance>, as of <date>)

## Executive summary
<2–4 sentences: how many tools, how many drifted, the single most consequential
finding. If nothing drifted, say so in one sentence.>

## Per-tool measurements
| Tool | State | Plan | PRs | Reviews | Approved | Inline | Sole-source | Caps |

## Drift findings
| Code | Tool | Severity | Divergence | Observed | Expected |

## Throughput
<PRs and reviews per day in the window — the figure Issue #1191's cap derives from.>

## What NOT to change
<Tools a careless reader would call redundant, and why they are not.>

## Follow-ups filed
## Filings suppressed as duplicates
## Caveats
<Truncation, unclassified cap candidates, unmatched baseline tools.>
## Cadence
```

On completion set `last_completed_month` and `last_completed_at` in the watermark,
through the same locked block as Step 1. `--report-only` **also** sets them: a dry
run still answered the month's question.

---

## Step 8 — Report to the user

**No drift: one line, and nothing else** (issue #1201 AC4):

```
[<ET timestamp>] review-stack-audit <MONTH>: no change — 6 tools, <N> PRs, 0 drift. Snapshot: <path>
```

**Drift found:** the count by severity, one line per finding (code, tool,
divergence), the issues filed with URLs, anything suppressed, and the report path.
Lead with the highest severity. If any caveat from Step 3 applies, say it here —
"0 drift with 3 unclassified cap candidates" is not the same claim as "0 drift",
and the user must not have to open the JSON to learn the difference.

---

## Exit criteria

**STOP** when all hold — and not before:

1. Every tool in the snapshot was compared, or the run is in bootstrap mode and
   said so.
2. Every drift finding is either filed or reported as suppressed, naming its
   target issue. **Nothing is silently dropped.**
3. The dated snapshot is on disk and the watermark records the month.
4. Every caveat that weakens the result — truncation, unclassified cap
   candidates, unmatched baseline tools, a degraded dedup lookup — appears in the
   user-facing summary, not only in the JSON.
5. Nothing outside `$STATE_DIR` (and, under `--report-to-repo`, the report and
   the README index line) was written. **No rule, skill, script, or config was
   edited.**
