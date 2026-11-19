## Ideas (issue #1766)

At the desk, `idea: <text>` (or `file: <text>`) files a GitHub issue without
leaving the desk and without switching it into capture mode
(`skill/ideas.md`). The filing is `/issue-maker`'s **one-shot entry**: the
same reflection, duplicate search, labels, seven-section body, and footer,
written up in `.claude/skills/issue-maker/references/one-shot-filing.md` and
created by the same script both use, `.claude/scripts/issue-file.sh`, which
refuses a body missing a section or the footer, drops labels the repo lacks
or that would hide the issue from `/pm`, and never assigns. The desk prints
the issue URL as its closing line.

- **Which repository.** `bin/idea-target.sh` reads the message on stdin: a
  first word that is `owner/name` or a GitHub link to a repository you can
  file issues in (checked with `gh repo view`), else this desk session's
  default (the state key `idea_repo:<session>`, checked again the same way
  each time, since access can change), else exit 3, and the desk
  asks once, in plain text, for `repo: owner/name`, suggesting the
  repository it runs in. `repo:` saves the default (and can change it any
  time). A path such as `desk/skill` stays in the idea's text.
- **Back as a Review.** The footer is what `sync-reviews` finds captured
  issues by, so the issue comes back as a Review like any other. Right after
  filing, the desk runs `filed OWNER/NAME N`:

  | Subcommand | What it does |
  |------------|--------------|
  | `filed OWNER/NAME NUMBER [--json]` | Records that the desk filed the issue. When its Review exists, one `commented` event, note `filed from the desk`, goes on it now (`noted R-12`); otherwise a pending filing waits as the reserved state key `filed:<owner/name>:issue-<N>` (lowercased; `pending`). Again is a no-op: a Review never gets a second note |

  `sync-reviews` consumes the pending filings whose Review exists, after its
  inserts and in the watermark's transaction: the event goes on, the key is
  deleted, and the tally adds `; N desk filing(s) noted on their Reviews`
  (`desk_filings_noted` in `--json`). `state set` refuses `filed:` keys. No
  migration: `state`, `events`, and the `commented` kind exist since 001.
- **Picked up by `/pm`.** An open, unassigned issue without an excluded label
  is what `/pm` ranks; its Step 1B.2 block `pm-1b2-new-issues` names every
  such issue created since the repo's last backlog scan (`NEW_ISSUES`), adds
  it to the shortlist, and shows it with its tier, on a cold start and on a
  backlog refill.
- **Stored.** Never the idea's text: only the session's default repository
  and the pending filing, both state rows, plus the Review's one event.
- **Tests.** `tests/ideas-offline.test.sh` (offline: `idea-target.sh`'s
  precedence and refusals against a `gh` stub and a store stub, the skill's
  `desk-idea-target` and `desk-idea-file` blocks run as written, `filed`
  and `state set filed:…` validation, the router); `tests/ideas.test.sh`
  (live, throwaway schema: pending, consumed by `sync-reviews` into one
  event, noted at once when the Review already exists, never twice).
  `issue-file.sh` and the `/pm` block have their own suites under
  `.claude/scripts/tests/` (`issue-file.test.sh`,
  `pm-backlog-new-issue.test.sh`).
