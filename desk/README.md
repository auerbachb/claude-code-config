# desk/ — the human queue

One store and one CLI for everything that needs the operator: **Decisions**
(questions that hold an agent) and **Reviews** (landed work). The design and
its reasoning are in [`DESIGN.md`](DESIGN.md); this file is the operating
contract for the code. Everything for the queue lives in this folder so it can
be spun out as its own project later.

Quick links: [Setup](docs/provisioning.md) · [CLI](docs/items.md) · [Capture hook](docs/capture-hook.md) · [Tests](docs/tests.md).

## Layout

| Path | What it holds |
|------|---------------|
| `bin/human-queue.sh` | The CLI, and the only program that reads or writes the store |
| `bin/cmd/<name>.sh` | One file per subcommand, found at run time |
| `bin/lib/common.sh` | One-line diagnostics, exit codes, `HUMAN_QUEUE_SCHEMA` |
| `bin/lib/db.sh` | Connection handling: URL parsing, the two-second probe, psql |
| `bin/lib/items.sh` | Item ids, input checks mirrored from the schema, the shared item renderer |
| `bin/lib/lifecycle.sh` | The answer transaction shared by `answer` and `set-resolve`, row locking, the `!reason` refusal protocol |
| `bin/lib/secrets.sh` | The secret-shape detector behind exit 5 |
| `bin/desk-cli.sh` | `human-queue.sh` for the desk: same arguments, the store's URL found the way the capture hook finds it (see "The desk") |
| `bin/desk-policy.sh` | The effective `policy.json` as one JSON object, through the capture hook's parser (see "Interrupts, policy, and feedback tags") |
| `bin/desk-tick.sh` | The `/desk` Monitor loop (see "The desk") |
| `bin/wake-target.sh` | A Decision's return address → the running session's messaging address (see "The desk") |
| `bin/idea-target.sh` | Which repository a desk idea is filed in (see "Ideas") |
| `bin/lib/filings.sh` | The desk's pending filings, shared by `filed` and `sync-reviews` (see "Ideas") |
| `bin/lib/report.sh`, `bin/lib/report.jq` | The weekly attention report's thread-model lookup and its one-page rendering (see "Weekly attention report") |
| `bin/lib/todo.sh` | The operator's to-do layer: tag and snooze-time parsing, and the one locked write `tag`, `untag`, `note`, `snooze`, `unsnooze`, and `mine` share (see "The to-do layer") |
| `bin/lib/budget.sh` | The reading budget's measurements from `events`, shared by `stats`, `checkin`, and `plan forecast` (see "Morning check-in and reading budget") |
| `bin/lib/impact.jq` | The derived-impact rule behind `impact` (see "Derived impact") |
| `bin/lib/export.sh`, `bin/lib/export.jq` | The paper copy's PDF renderers and its Markdown, text, and HTML rendering (see "Export to paper") |
| `schema/NNN_<name>.sql` | Migrations, applied by `human-queue.sh migrate` |
| `hooks/` | Hook implementations: `capture.sh` and its logic `capture.py`, the capture hook (see "Capture hook") |
| `policy.json` | The desk's defaults: tick cadence, interrupt rule, end of day, set size, live-desk bound (see "Interrupts, policy, and feedback tags"), and the critical-path thresholds (see "Derived impact") |
| `skill/` | The `/desk` skill: `SKILL.md` (router) and one file per kind of work (see "The desk") |
| `tests/` | `run.sh` plus `*.test.sh` suites |

The hook entries under `.claude/hooks/` are symlinks into this folder
(`human-queue-capture.sh` → `hooks/capture.sh`), and so is `.claude/skills/desk`
(→ `../../desk/skill`), so the repo's skill-symlink rule keeps holding.

## Operating manual

<!-- desk-docs-index:start -->
- <a name="provisioning-the-database-once"></a>[Provisioning the database (once)](docs/provisioning.md)
- <a name="environment"></a>[Environment](docs/environment.md)
- <a name="exit-codes"></a>[Exit codes](docs/exit-codes.md)
- <a name="items"></a>[Items](docs/items.md)
- <a name="lifecycle"></a>[Lifecycle](docs/lifecycle.md)
- <a name="sets"></a>[Sets](docs/sets.md)
- <a name="state-control-and-tick"></a>[State, control, and tick](docs/state-control-tick.md)
- <a name="account-bindings-issue-2183"></a>[Account bindings (issue #2183)](docs/account-bindings.md)
  - <a name="queue-owner-issue-2184"></a>[Queue owner (issue #2184)](docs/account-bindings.md#queue-owner-issue-2184)
  - <a name="one-queue-per-account-setup-notice-and-start-display-issue-2185"></a>[One queue per account, setup notice, and start display (issue #2185)](docs/account-bindings.md#one-queue-per-account-setup-notice-and-start-display-issue-2185)
- <a name="capture-hook"></a>[Capture hook](docs/capture-hook.md)
  - <a name="decisions-from-codex-cursor-and-other-tools"></a>[Decisions from Codex, Cursor, and other tools](docs/capture-hook.md#decisions-from-codex-cursor-and-other-tools)
- <a name="migrations"></a>[Migrations](docs/migrations.md)
- <a name="adding-a-subcommand"></a>[Adding a subcommand](docs/adding-a-subcommand.md)
- <a name="tests"></a>[Tests](docs/tests.md)
- <a name="the-desk-issue-1779"></a>[The desk (issue #1779)](docs/desk-interface.md)
- <a name="long-form-multipart-and-discuss-issue-1780"></a>[Long-form, multipart, and discuss (issue #1780)](docs/long-form.md)
- <a name="wake-up-retries-answer-parked-show-and-history-issue-1781"></a>[Wake-up retries, `answer-parked`, `show`, and `history` (issue #1781)](docs/wake-up-retries.md)
- <a name="priorities-the-operators-backlog-order-for-pm-issue-1767"></a>[Priorities: the operator's backlog order for `/pm` (issue #1767)](docs/priorities.md)
- <a name="reviews-issue-1756"></a>[Reviews (issue #1756)](docs/reviews.md)
  - <a name="sync"></a>[Sync](docs/reviews.md#sync)
  - <a name="summary-levels"></a>[Summary levels](docs/reviews.md#summary-levels)
  - <a name="github-access-and-tests"></a>[GitHub access and tests](docs/reviews.md#github-access-and-tests)
- <a name="the-reviews-view-issue-1782"></a>[The Reviews view (issue #1782)](docs/reviews-view.md)
- <a name="ideas-issue-1766"></a>[Ideas (issue #1766)](docs/ideas.md)
- <a name="prose-question-nudge-issue-1778"></a>[Prose-question nudge (issue #1778)](docs/prose-question-nudge.md)
- <a name="interrupts-policy-and-feedback-tags-issue-1783"></a>[Interrupts, policy, and feedback tags (issue #1783)](docs/interrupts-policy-feedback.md)
- <a name="day-plan-and-end-of-day-sweep-issue-1784"></a>[Day plan and end-of-day sweep (issue #1784)](docs/day-plan.md)
- <a name="weekly-attention-report-issue-1771"></a>[Weekly attention report (issue #1771)](docs/weekly-attention-report.md)
- <a name="the-to-do-layer-issue-1769"></a>[The to-do layer (issue #1769)](docs/todos.md)
- <a name="pr-drill-down-issue-1768"></a>[PR drill-down (issue #1768)](docs/pr-drill-down.md)
- <a name="morning-check-in-and-reading-budget-issue-1770"></a>[Morning check-in and reading budget (issue #1770)](docs/morning-check-in.md)
- <a name="derived-impact-issue-1760"></a>[Derived impact (issue #1760)](docs/derived-impact.md)
- <a name="review-batches"></a>[Review batches](docs/review-batches.md)
- <a name="export-to-paper-issue-1759"></a>[Export to paper (issue #1759)](docs/export-to-paper.md)
<!-- desk-docs-index:end -->

### Queue owner: decisions (issue #2184)

- **The queue knows its owner.** `bind` stamps the queue with the account's binding name under the reserved `queue_owner` state key. `register-control`, `tick --session`, and `add` refuse a caller whose name differs (exit 4, one line naming both, nothing written). `bind` (and `carry-over`, which runs `bind`) runs `owner set NAME`, the only path that stamps an unstamped queue; `owner transfer NAME --confirm` is the explicit move to another owner, and it reports the open items first.
- **Unstamped queues refuse named calls** with instructions to bind. Unnamed calls on unstamped queues are unchanged. The capture hook fails open either way: the menu renders and one warning line is printed.
- **The stamp is the name, not the signed-in identity (decided: name only).** No hook or CLI input reliably exposes the signed-in account without reading credential-adjacent profile state, and an email would put personal data in the queue. A profile re-logged into a different account therefore still matches its name; this gap is accepted and revisited only if an identifier becomes available to hooks without touching credentials.

Details, the test seam's name rule, and the tick loop's stop: [Account bindings](docs/account-bindings.md#queue-owner-issue-2184).

### One queue per account (issue #2185)

- **One queue per account.** Each account binds to one queue. A new account starts unbound, and a copied profile never inherits another account's queue.
- **Commands.** `desk-cli.sh bind --name <name> --schema <schema>` binds the account; `desk-cli.sh bindings` lists accounts; `desk-cli.sh bindings --current` prints `account: <name>  queue: <schema>` for this account from the registry alone.
- **Refusals.** An unbound account exits 4 with the bind command. A queue owned by another account is refused by `bind` (exit 4, nothing recorded).
- **Start display.** `/desk` checks `bindings --current` first and shows the account and queue before the first tick.
- **Setup notice.** `share-config` strips `HUMAN_QUEUE_SCHEMA` from a copied `settings.json` and prints one `desk queue:` line (or `no desk queue — run ... bind ...`) per Claude profile.

Details: [Account bindings](docs/account-bindings.md#one-queue-per-account-setup-notice-and-start-display-issue-2185).
