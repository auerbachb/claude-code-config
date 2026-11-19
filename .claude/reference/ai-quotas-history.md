# AI Quota Tracking — snapshot history, the daily job and burn-rate projection

Part of the quota reference — start at [`ai-quotas.md`](./ai-quotas.md). The display-only rule, the reserve exception and the separate-wallet boundary stated there apply to this file.

## Snapshot history, the daily job, nicknames (increment 5, #1700)

`/quotas` answered "where does each account stand **now**". A single reading cannot tell
"used 57 % over six days" from "used 57 % since yesterday", so this increment records
every reading, takes one unattended reading a day so quiet days leave no hole, and
narrows the table enough to read five accounts at a glance.

**History is display data, exactly like the table it comes from.** Nothing in this repo
reads `ai-quotas-history.jsonl` to decide whether work may proceed, and nothing may
start: no dispatch gate, no pause, no model downgrade, no input to `credit-budget.sh`.
Quota and spend authority stays with Anthropic's own in-app UI and upstream harness
signals — `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority", with the
rolled-back `/quota` skill (#499) as the precedent for what gating on locally-read
numbers costs. The projection in #1701 is the file's first and only reader, and it is a
projection printed to a human, not a verdict.

### The history file

- **Path** `~/.claude/ai-quotas-history.jsonl` (override with `AI_QUOTAS_HISTORY`)
- **Mode** `600`, created through a `077` umask so it is never briefly world-readable
- **Format** JSON Lines: one object per line, append-only, never rewritten

Every run of `ai-quotas.sh` appends one line per **successfully read** row:

```json
{"ts":"2026-09-10T13:00:04Z","provider":"codex","label":"admin@localmovers.com",
 "nickname":"GPT LM","window":"7-day","used_pct":71,"resets_at_epoch":1789200000,
 "source":"scheduled"}
```

| Field | Meaning |
|-------|---------|
| `ts` | UTC ISO-8601 instant of the RUN, identical on every line the run appends — so a run is a group, not a scatter of near-equal times. |
| `provider` | `claude`, `codex`, or `cursor`. |
| `label` | The registry label, which is the stable key across renames of the nickname. |
| `nickname` | The nickname at the time of the reading, or `null`. Recorded rather than looked up later, so a renamed account keeps its old readings labelled the way they were shown. |
| `window` | The row's **pool** where the provider has pools, its window otherwise — the same value the table's third column shows. This is what makes a Cursor account's two pool rows two distinct series rather than two readings of one; a burn rate computed without it would average two unrelated pools. |
| `used_pct` | The percentage the row reported. Never `null` — a row without a figure appends nothing at all. |
| `resets_at_epoch` | When that window resets, or `null`. A series crossing a reset is what tells a projection where one cycle ended. |
| `window_start_epoch` | When the window that reading belongs to OPENED, or `null` (#1701). Derived per provider — `resets_at − 604800` for a Claude week, `resets_at − windowDurationMins × 60` for Codex, the billing-cycle start Cursor itself reports. Recorded rather than re-derived at read time: the reset time can move, and a line carrying its own window start can be assigned to a cycle months later without knowing what the window length was then. |
| `source` | `manual` for a hand-run `/quotas`, `scheduled` for the unattended job (`--quiet`, or `AI_QUOTAS_SOURCE=scheduled`). An unrecognised `AI_QUOTAS_SOURCE` is refused on stderr and the run records `manual`. |

**Lines written before #1701 have no `window_start_epoch`,** and they stay readable: the
projection derives a window start from the row's label and reset time (`7-day` →
`resets_at − 7 days`) where it can, and treats the line as unusable where it cannot.
Nothing rewrites the file to add the field — the history is append-only, and a reader
that needs a field older lines never had is a reader that must degrade, not a reason to
rewrite a record.

**A failed row appends nothing.** No line with a null percentage: three months later such
a line is indistinguishable from a genuine reading, and a projection averaging it would
treat a failure as a `0`. The statuses in the table already say which accounts did not
read.

**Every failure here is non-fatal and loud.** An unwritable history file changes neither
the table nor the exit status — a display tool that started failing because its optional
log was unwritable would be a gate by accident — but it always says so on stderr, because
a hole in the record with nothing explaining it is exactly what a projection would
misread as a quiet day.

**No retention policy, deliberately.** CodeRabbit proposed one during local review and
it was declined for this increment: the daily job writes one line per account per day —
five accounts is under 400 KB a year — and a projection over a longer history is strictly
better than one over a truncated one, so the first thing a retention rule would delete is
the data #1701 exists to use. Revisit it if the file ever becomes large enough to notice,
which at this rate is years away.

**Concurrency.** The whole run's lines are appended in ONE `cat >>`, not one write per
row. A hand-run `/quotas` while the LaunchAgent happens to fire is the ordinary case, and
appending once keeps that block contiguous instead of interleaving it row by row with the
other run's. This narrows the window; it is not atomicity, and the distinction is the
point. `cat` writes in buffer-sized chunks, so a block larger than one chunk becomes
several `O_APPEND` writes and a concurrent appender can land between them. The cost is
bounded: `O_APPEND` advances the offset atomically per write, so the two runs never
overwrite each other and nothing written on an earlier day can be damaged — the only
casualty is the pair of records straddling a chunk boundary, which arrive torn. Readers
use `fromjson?` per line and skip what does not parse, so a torn line (from this, or from
a run killed mid-append) costs only itself, and the next run records again. A lock was
declined for the same reason a retention policy was: it would buy those two records at
the price of a stale-lock failure mode on a file whose whole contract is that it never
blocks the report it decorates.

**Reading order is not append order.** Every row of a run carries the clock that run
*started* on, while its position in the file is where the run *finished* — so a slow run
that began at 09:00 and appended at 09:05 sits after a quick one that began at 09:02. The
`LAST SNAPSHOT` footer therefore takes the newest `ts`, not the last line; the timestamps
are fixed-width UTC `%Y-%m-%dT%H:%M:%SZ`, so ordering them is a lexicographic sort.
`/quotas-setup schedule status` keeps its own copy of that lookup and sorts identically —
two commands answering "when did the job last run" differently is worse than either
answer being wrong. Anything else reading this file for a latest value owes itself the
same care.

**The history path is never followed through a symlink.** `-f` is true for a link to a
regular file and `-e` is false for a dangling one, so the plain tests would have let the
`chmod 600` retarget an unrelated file's mode, the append write quota JSON into it, and a
dangling link bring its target into existence. A symlink at that path is refused outright,
with a warning, before the create, the mode check, or the append — the run still exits 0,
because this is a record and not a gate.

### The daily unattended job

`/quotas-setup schedule install` writes `~/Library/LaunchAgents/com.claude.ai-quotas.plist`
(override with `AI_QUOTAS_LAUNCH_AGENT`) and loads it.

| Plist key | Value |
|-----------|-------|
| `Label` | `com.claude.ai-quotas` — also the launchctl service name. |
| `ProgramArguments` | The absolute path to `ai-quotas.sh`, then `--json --quiet`. |
| `RunAtLoad` | `true`, so installing it takes a reading immediately rather than waiting for tomorrow. |
| `StartCalendarInterval` | `Hour` **9**, `Minute` 0, local time. `--hour <0-23>` (or `AI_QUOTAS_SCHEDULE_HOUR`) changes it. |
| `StandardOutPath` / `StandardErrorPath` | `~/.claude/ai-quotas/launchd.log` (override with `AI_QUOTAS_LAUNCHD_LOG`). |
| `EnvironmentVariables` | `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` and `HOME`, plus `AI_QUOTAS_CONFIG` and `AI_QUOTAS_HISTORY` when the installing shell had them set. |

**Why 09:00.** launchd runs a missed calendar job at the next wake rather than skipping
it, but a reading taken hours late is a reading attributed to the wrong day; 09:00 is
late enough that the Mac is normally awake and early enough that the day's usage has not
yet accumulated, so consecutive snapshots measure a day apart rather than a day plus
however long the owner slept in.

**Why the explicit `PATH`.** launchd hands a job a minimal environment — typically
`/usr/bin:/bin:/usr/sbin:/sbin`. Every tool the reader needs beyond the base system lives
in Homebrew's prefix: `jq`, `codex`, and `node` are all under `/opt/homebrew/bin` on this
Mac (`/usr/local/bin` on Intel). Without it the scheduled run finds no `jq`, exits 5, and
writes a hole in the history every night.

**Why the path overrides are carried.** `AI_QUOTAS_CONFIG` and `AI_QUOTAS_HISTORY` each
override a `HOME`-derived default, so a shell that has one set gets it honoured by every
command the owner types — `schedule install`, `schedule status`, `/quotas` itself — while
a job that did not inherit it would resolve the default instead. The result would be two
history files, each looking complete, neither holding every reading. `AI_QUOTAS_PROFILE_ROOT`
is deliberately *not* carried: the reader never consults it, taking each account's
`profile_dir` from the registry (already absolute), so passing it would advertise an
effect it does not have.

**Why a re-install can report the previous definition.** launchd holds a job by label,
not by path. `schedule install` boots the old job out before bootstrapping the new plist,
but when the bootout does not take, neither `bootstrap` nor the legacy `load -w` can
replace it — and `launchctl list` keeps answering "loaded", because something under that
label is. The install says so explicitly rather than reporting success: the plist on disk
is the new one and takes effect at the next login, but until then the job running is the
one loaded before the install, at the old hour and the old reader path.

**Why launchd and not cron, and not a Claude scheduler.** The reader needs this user's
login context: the Keychain items the `claude` login created, the per-account
`CODEX_HOME` directories, the Cursor IDE's state store. A per-user LaunchAgent runs inside
exactly that context. A cron line or an agent-side scheduler would run the same reader
with none of it and record `needs-login` every day — not a gap in the history but a
history full of confident wrong answers. The `mcp__scheduled-tasks__*` scheduler is
declined for the same reason it is declined elsewhere
(`.claude/reference/cross-session-durability.md`), plus this one.

**The scheduled run opens no browser at all.** Since #1703 the Cursor read is `sqlite3`
plus `curl` — there is no browser left to launch headed or headless, so the bot-check
caveat #1668 carried under launchd is gone with it. A Cursor IDE that is signed out
yields a `needs-login` row, never a prompt and never a window appearing on the owner's
desktop at 09:00.

**Which copy of the reader gets scheduled.** The plist must outlive any checkout, so the
path is resolved `~/.claude/skills-worktree/.claude/scripts/ai-quotas.sh`, then
`~/.claude/scripts/ai-quotas.sh`, then the script's own sibling — and choosing the
sibling prints a warning naming the problem, because a LaunchAgent pointing into a
worktree keeps working until that worktree is removed and then fails every night into a
log nobody reads. `AI_QUOTAS_READER_BIN` overrides all three and is used **exclusively**
when set, for the same reason `AI_QUOTAS_CHEAPEST_BIN` is: a seam that falls back finds
the repo copy whenever the caller stands in a checkout, so the "reader unresolvable" path
could never be exercised from the one place the suite runs.

`schedule remove` runs `launchctl bootout gui/$(id -u)/com.claude.ai-quotas` (falling back
to `launchctl unload -w`) and deletes the plist; the recorded history is left alone.
`schedule status` reports the plist as present or absent, the job as loaded or not, the
log path, and the `ts` of the most recent `scheduled` snapshot. On a host that is not
macOS all three print one line and exit **2**.

`install` is idempotent: it boots out an already-loaded job before bootstrapping the new
plist, because `bootstrap` refuses a label launchd already holds and a re-install without
that would leave the OLD definition running while the new plist sat on disk looking
installed. Where `bootstrap` is unavailable it falls back to `launchctl load -w`.

### Nicknames and the compact table

`add <provider> <label> --nick <name>` and `nick <label> <name> [<provider>]` store
`nickname` in the registry; `/quotas` prints it in the ACCOUNT column in place of the
provider-reported email. The note still says `registered as <label>` whenever the label
differs from the reported email, so a nickname shortens a row without hiding which
registry entry produced it.

The table dropped **REMAIN** (it was `100 - USED` on every row) and the NOTE column now
carries **actionable text only** — the mislabelled-account warning and the row's detail.
`plan pro` and `via app-server` moved to `--json`: they are provenance, there is nothing
to do about either on an `ok` row, and together they were the widest thing on a healthy
one. `remaining_pct`, `plan`, and `source` are all still on every `--json` row —
dropping a derived column from the display is not a reason to break a consumer.

**The column budget.** The table first had a 100-column budget (five accounts at 98). The
FETCHED, paid-usage, resets and top-tier columns moved it to **140 terminal columns for
six accounts** (Issue #2409): `ai-quotas-columns.test.sh` measures the widest line of a
six-account render (Claude Personal and Work, two Codex, Cursor, Antigravity) with the two
icons counted as two columns, and the older table suite holds the five-account render to
the same 140. What makes room is described in "Paid usage, resets and top tier" in [`ai-quotas-reader.md`](./ai-quotas-reader.md):
one space between cells, and a note or overage label too long for its cell printed as a
numbered footnote under the table instead of inside the row. Nothing is truncated: a
`/quotas-setup relogin` command or a Cursor `on-demand $1007.50 of $1000` label is printed
in full, one line under the table.

Under the table, `LAST SNAPSHOT` names the most recent **scheduled** snapshot —
`stale (>1 day)` past 24 hours, `none yet` (with the install command) when the job has
never run. Manual snapshots deliberately do not count: the line is about whether the
unattended job is working. `--json` carries the same instant in
`last_scheduled_snapshot_at`, on every document including the two empty ones, so there is
nothing for a consumer to special-case. `--quiet` drops the footer and the cheapest-next
prose — under the unattended job they would only tell the job log about itself — but it
does **not** silence stderr, because the log is the only place a broken scheduled read
can be noticed.

### Test seams added at #1700

`AI_QUOTAS_HISTORY` and `AI_QUOTAS_SOURCE` on the reader; `AI_QUOTAS_LAUNCH_AGENT`,
`AI_QUOTAS_LAUNCHCTL_BIN`, `AI_QUOTAS_READER_BIN`, `AI_QUOTAS_LAUNCHD_LOG`,
`AI_QUOTAS_HISTORY`, and `AI_QUOTAS_SCHEDULE_HOUR` on the setup script. The plist, the job
log, and the history file otherwise resolve from `HOME`, which the suites already
redirect — so no case can touch the real `~/Library/LaunchAgents` or the owner's own
registry.

> **No apostrophes inside the reader's `jq` programs.** They are single-quoted shell
> strings, and one apostrophe in a jq comment closes the string; bash then parses the jq
> source and reports a syntax error a hundred lines from the comment that caused it.
> A comment reading "the row's detail" cost a full test-suite round to find.

## Burn-rate projection (increment 6, #1701)

A weekly cap that is 57 % used means something different on day two than on day six.
This increment reads the history above and answers the question the percentage does not:
**when did usage start in this window, how fast is it going, and how long does that
leave.** `.claude/scripts/quotas-forecast.sh` owns the arithmetic, annotating the
document `ai-quotas.sh --json` builds — the same row-in / row-out shape
`quotas-cheapest-next.sh` uses, for the same reason: a pace is a property of the recorded
history, not of any single read.

**Informational only, and this is the last place the boundary needs restating.** The
projection **never gates dispatch, never pauses, defers, or downgrades anything, and
never feeds `credit-budget.sh`.** It is the same third observational surface the table
and the cheapest-next hint are — `.claude/rules/safety.md` §"Anthropic Quota & Spend
Authority" holds the authority, and the rolled-back `/quota` skill (#499) is the
precedent for what gating on locally-read numbers costs. A days-left figure is a
sentence printed to the owner, and the owner decides what to do with it.

### The three columns

| Column | What it is |
|--------|-----------|
| `START` | The first day of this window any usage was recorded, as the ET weekday plus `d<N>` — `Wed d3` is "day 3 of the window, a Wednesday". A `<=` prefix (`<=Tue d2`; the table prints it as `≤Tue d2`, see below) means the record does not reach back to the window start, so usage may have begun earlier: the day shown is the **latest** it can have been. |
| `%/DAY` | `used_pct / max(days_since_start, 1)`, one decimal. The `max` is what keeps a window whose usage started today from dividing by nothing. |
| `LEFT` | `remaining_pct / pct_per_day` in days, one decimal — or `resets first` when that runs past the reset, because the window comes back before the account runs out. |

`-` in any of the three means there is nothing to project: no window to place the reading
in, no usage yet (a 0 % row has no pace), or a row that did not read. Never a `0`, which
would read as "nothing is being spent".

### How the series is built

- **This account, this pool, this window.** History lines match on `provider`, `label`,
  and `window` — where `window` is the row's pool when the provider has pools, exactly as
  the history records it. A Cursor account's two pools are two series; averaging them
  would report a pace nobody set.
- **This window only.** A line whose `ts` falls before the window opened describes a
  cycle that has already reset. A line that recorded its **own** `window_start_epoch` is
  checked against this row's as well, and dropped when the two are more than half a
  window apart — near rather than equal, because a provider may move a reset by an hour
  inside a cycle and strict equality would then drop every earlier line and report every
  day as a fresh floor start.
- **A reading has to be inside its own window.** When the reset has already passed and
  the provider is still reporting the old figure, nothing is projected: placing today in
  that window would print `d9` of a seven-day one and measure a runway against a reset in
  the past.
- **Remaining is floored at zero.** Cursor percentages are not clamped at 100, and a
  negative remainder over a positive rate would print a runway of `-0.4` days.
- **Plus this run's own live reading**, in memory rather than from the file. That is what
  makes the first run project at all, and what keeps a run whose history append failed
  from silently reporting a stale pace.
- **One reading per day, the later one winning.** Day granularity is what was asked for;
  a rate computed over two readings an hour apart swings wildly. A hand-run `/quotas` at
  8 pm supersedes the unattended reading at 8 am rather than competing with it.

### The floor, and why the rate moves with it

When the earliest snapshot **in** the window already shows usage, nothing recorded proves
usage did not start sooner. The row is marked `usage_start_is_floor: true`, the cell gets
its `<=`, and the rate is computed **from the window start** rather than from the
snapshot. That is the slowest pace consistent with the record, which is the honest
direction to be wrong in — computing from the snapshot would divide by a shorter elapsed
time, report a faster burn, and promise a shorter runway than the evidence supports.

### `<=` in `--json`, `≤` in the table, `-` for every unknown

The table used to be aligned by `column -t`, which pads by counting **bytes** under the C
locale this fleet runs in, so a three-byte `≤` shifted every column to its right on that
row and the table used `<=` instead. Since Issue #2409 the reader lays the table out
itself (jq pads by characters and counts the two ✅/❌ icons as two terminal columns), so
the table's START cell prints the one-column `≤` and saves a column. `usage_start_display`
in `--json` and the forecast helper keep the ASCII `<=`, which survives a pipe into
anything. `-` is the marker every other unknown in this table already uses.

### What the table gave up to fit

Three columns had to come from somewhere, and a five-account table has to stay inside 100
columns to be read at a glance:

- **The PROVIDER column is gone.** It was fixed-width and repeated what the account name
  already tells the owner — the same trade #1700 made when it dropped REMAIN. `provider`
  is still on every `--json` row.
- **STATUS folded into NOTE.** The status word now leads the note on any row that is not
  `ok` (`needs-login; /quotas-setup relogin …`), which is where the instruction about it
  already lived; an `ok` row says nothing, which is what `ok` was worth as a column. The
  vocabulary is unchanged, the two are now read as one sentence rather than as two
  columns that have to be crossed, and `status` is still on every `--json` row and is
  still the field to branch on.
- **RESETS shows a weekday and a time** (`Thu 8:00 PM`) rather than a full date with a
  zone. The countdown beside it says how far away that is and the heading says ET.
  `resets_at_et` keeps the long form for consumers; `resets_at_et_short` is the new field
  the table prints.
- **The countdown lost its `in ` prefix** — the `IN` heading supplies it.

The measured promise is the **clean** five-account table, exactly as it was at #1700: a
row carrying a relogin note, or a `resets first` cell, is wider, and always has been.
`.claude/scripts/tests/ai-quotas.test.sh` measures it rather than eyeballing a fixture.

### Test seams added at #1701

`AI_QUOTAS_FORECAST_BIN` on the reader — used **exclusively** when set, like
`AI_QUOTAS_CHEAPEST_BIN`, so the "helper unavailable" path can be exercised from inside a
checkout — and `AI_QUOTAS_HISTORY` plus `AI_QUOTAS_NOW` on `quotas-forecast.sh` itself.
The reader passes both through explicitly rather than letting them be inherited: a
projection that read a different history, or a different instant, than the table above it
would disagree with the table it decorates.

### A projection may only fill blanks

That seam is also the reason the reader cannot take the helper's word for what came back.
`AI_QUOTAS_FORECAST_BIN` points it at an arbitrary executable, so the returned document is
checked against the one that was sent: same rows, and every field that already **carried a
value** — `schema_version`, the threshold and basis, `cheapest_next`, and on each row the
provider, label, status and the figure itself — returned unchanged. A field that was
`null` on the way in is one the helper is there to fill — and only the **seven** it owns:
`usage_start_epoch`, `usage_start_is_floor`, `usage_start_day`, `usage_start_display`,
`pct_per_day`, `days_left`, `days_left_note`. A figure appearing in `overage` (null on
every row whenever the cheapest-next helper degraded) came from no provider, and the
table has no way to say so.

The key set is identical besides, top level and every row. A blank the helper **deleted**
instead of filling would leave the field off the document, and one report shape whatever
ran is exactly why those fields are declared `null` on rows nothing was projected for; a
key that was never **sent** has no legitimate way back, because every value the projection
writes already has a null waiting for it.

Counting rows is not enough. A same-length document that dropped `schema_version` or a
row's `provider`, or that rewrote a `used_pct` this run actually measured, is well-formed,
passes a shape check, and prints a report missing or misstating the fields a consumer
reads it for — with exit 0. Any such document is discarded **whole**: `$DOC` stays exactly
as it was, the three projection columns keep their `-`, and stderr says `DEGRADED` once.
Half a projection is not better than none, because nothing downstream could tell which
half it got.
