# Independent areas

Add `## Independent areas` to the repository's `.claude/pm-config.md` when it has services that can safely change in parallel. Uncomment only rows that describe boundaries the repository actually has.

| Area | Paths | Labels | Keywords |
| --- | --- | --- | --- |
| billing | `services/billing/`, `billing.toml` | billing, team:billing | invoice, payment retry |
| mailer | `services/**/mailer/` | mailer | outgoing email |
| web | `apps/web/` | web | web client |

Area names are unique case-insensitive slugs. `Paths` is required. Labels and keywords are optional. Separate multiple entries with commas. Use case-sensitive, repo-relative globs with letters, digits, dots, underscores, dashes, and slashes. The supported wildcards are `?`, `*`, and `**/`. As in [review policy](review-policy.md), `*` crosses directory separators, `**/` can match zero directories, and a trailing slash, `/*`, or `/**` covers the directory and its descendants in the launch comparison. One path can match several areas.

`/wave` uses plans, declared paths and subject inference first. For a candidate without a path, a single exact case-insensitive label match selects its area. With no matching label, a single case-insensitive whole-word or whole-phrase match in the title or body selects it. Multiple matches at either stage leave the issue undeclared. Labels can contain punctuation, such as `team:billing`.

A pathless issue with a resolved area overlaps another area footprint with the same name. It also overlaps a path footprint with a path in that area. Two path footprints continue to use their exact paths and declared coupling. Dependency edges and inferred subject overlap still apply. An area whose globs cover a shared surface takes that surface into the same launch comparison. Unplaced candidates retain the one-undeclared allowance. `/subagent` uses these same checks when it forms launch chains.

With no active table, the prior checks apply. Fenced examples and HTML comments are ignored. A malformed active table or repeated active section causes one diagnostic and falls back to the prior checks for the batch. `/pm-handoff` leaves proposed rows commented on bootstrap and preserves the section on refresh.
