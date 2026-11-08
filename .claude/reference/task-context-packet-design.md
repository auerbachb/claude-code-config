# Compact task packets on existing state owners

Issue #1876. **Decision: use a derived, bounded index; retain GitHub claims,
worktrees, scoped session/handoff records and existing gates as authorities.**
This deliverable is a design and offline fixtures, not a deployed packet
assembler, lock service, tracker migration or performance/savings result.

## Evidence and provenance

Static inspection at `bec82106e1cb4a4a64eb94bc1243cfdf8dfc2e1a`:

| Mechanism | Checked source | What it establishes and does not establish |
|---|---|---|
| Incremental skill loading | `.claude/skills/issue-maker/SKILL.md`, module index and steps 4–5 | Index first, active module on demand; checkpoints before/after operation phases. This does not make all giant skills incremental. |
| Claim acquisition | `.claude/scripts/issue-claim.sh`, `action: --claim` through final `emit mine` | Label/assignee and marker writes; rollback on marker failure. Its final reread prefers GitHub's timestamp if the winning marker is this holder's, but a different winning holder or failed reread does not prevent the final success. This is not atomic ownership acquisition. |
| Claim renewal | Same helper, `RENEWAL` contract and `renew_claim` | Renewal already exists, verifies the replacement, withdraws on loss/release, and uses final reread/repair. Do not propose adding renewal again. A takeover whose stale read precedes verification can still race. |
| Existing ownership/adoption | `.claude/scripts/candidate-ownership.sh`, read-only sweep and adoption evidence | Uses claims, session state, PRs and handoffs to find an owner/resume route; uncertainty is not proof that a task died. A packet adds no death detector. |
| Launch-side overlap | `.claude/skills/subagent/SKILL.md` step 6.0b and `/wave` footprint rules | Same-batch overlapping files/coarse collision surfaces form serialized chains; undeclared scope is conservative. This is already implemented policy, not a new packet proposal. It is not a cross-thread atomic reservation of every issue's files. |
| Merge-side overlap | `.claude/scripts/merge-sequence.sh`, `.claude/reference/merge-sequencing.md` | Sequences open PRs using actual shared files, bounded holds and anchor state. It cannot prevent two earlier independent threads from editing overlapping files. |
| State writes | `.claude/scripts/session-state.sh` (`--cas`, `--set`), `handoff-state.sh`, `state-lock.sh` | Existing locks/CAS protect those state transactions; they do not atomically combine GitHub claims, Git status and model dispatch across machines. |
| Resume evidence | `.claude/reference/handoff-file-schema.json`, `handoff-files.md`, phase-agent definitions | Keeps current HEAD, findings, files, reviewer and phase in a scoped handoff; independent verification still owns review/merge readiness. |

The acquisition observation above is a source-level race analysis, not a live
reproduction. The offline fixture walkthrough below is executed verification of
the **proposed packet rules**, not a concurrency test of GitHub. The older
CodeRabbit plan's statements that there is no renewal or no reread are stale.
No external playbook savings, Graphban feature claim or platform advantage is
established by this inspection; none is needed for this design.

## One index, authoritative detail on demand

The packet is disposable. Rebuild it from the records below; never reconcile
GitHub or canonical state *from* a packet. The issue spec and **all** acceptance
criteria remain authoritative in GitHub. Do not copy whole skills, transcripts,
all phase histories or raw logs into the default packet.

| Index field | Canonical source and binding |
|---|---|
| `identity` | Repository slug, issue, worktree, branch, current full Git HEAD; verify the checkout still belongs to that repo/issue. |
| `spec` | Issue URL, `updatedAt`, SHA-256 of body, full AC count and a pointer to full spec/AC; load complete criteria before implementation/verification. No truncated AC substitute. |
| `ownership` | Exact claim holder, author, marker ID and timestamp, plus session/task identity when actually supplied by the runtime; live claim recheck is mandatory. |
| `phase` | Current operation/phase and one active module pointer/hash from the existing lazy-loading index. Load only that module and its explicitly triggered references. |
| `touchpoints` | Declared repository-relative files/symbols with lexical `./` and `..` normalization and source-plan pointers; use the existing `/wave` collision-surface rules, including `rule-corpus`. Unknown footprint stays unknown. |
| `verification` | Short list of relevant commands with working directory and existing results' pointers; evidence is bound to repo/HEAD, not implied by command presence. |
| `recovery` | Selected scoped handoff/session pointer, recorded HEAD/phase, compact discoveries, attempted approaches, remaining blocker and next action. Retain the authoritative attempt history at its source. |
| `evidence` | IDs/URLs/paths with repo, observed HEAD, source revision/digest and validity status. CI/review/AC remain independently verified live gates. |
| `sources` | Revision stamps/digests of selected issue, handoff, relevant session subtree and active module; acquisition time and revalidation triggers. |

Keep only the active task/phase index in existing task/PR state or a scratch
artifact referenced by it, written through the current locked state helper.
Do not introduce a second packet database or another authoritative claim table.
For any future task-index field, use an explicit `.repos["owner/repo"].tasks[...]`
path: `session-state.sh --repo` automatically rewrites `.prs`/`.root_repo`, not
arbitrary new top-level keys. Verify same-numbered issues in two repositories
remain independent before wiring a caller.
Issue #1877's explicit runtime task/session links may be referenced; a missing
ID/cost stays unknown. Issue #1875's task/phase retry record supplies discoveries
and escalation evidence once its change lands; a packet never decides the tier.

### Starting bounds and overflow behavior

An index is at most **8 KiB of UTF-8 JSON**, with at most 16 touchpoint entries,
8 verification commands and 8 evidence pointers. These are design defaults for
fixtures, not measured optimal thresholds. Store detail at canonical pointers;
do not silently slice a list to fit. Overflow produces `needs_detail` with
counts and a source pointer; load the necessary complete detail before acting.
If even the minimal identity/source index exceeds the byte bound, refuse the
packet and retrieve the canonical task directly. Safety/ownership/gates are
never optional context removed to fit a limit.

The full spec/AC are not duplicated into the index. A large issue therefore
does not lose its later criteria. Before changing code or checking AC, retrieve
the referenced full body and verify its digest; changed or unreadable bodies
invalidate prior decisions. The index's counts alone cannot certify completion.

## Freshness and trust

An index older than **15 minutes** is a retrieval hint only; refresh its sources
before acting. Revision equality does not replace a live ownership check. On
every launch, resume, phase transition, changed HEAD, new finding, claim change,
module change or explicit owner correction, rebuild/revalidate the relevant
bindings even if younger than fifteen minutes.

Compare the issue body revision/hash, actual repo/worktree/HEAD, current owner
marker, handoff HEAD/phase, relevant session subtree digest and module hash.
Any mismatch makes the packet stale and names what to retrieve. Missing,
unreadable, wrong-repository or wrong-HEAD evidence is `unknown`, never a pass. A nonempty URL is not a readability check: the canonical read must succeed and its observed repo, HEAD and revision must match the indexed metadata. The offline walkthrough models that retrieval explicitly with fixture read observations. All four selected source stamps (issue, handoff, session and module) must be present and nonempty on both sides before equality can establish freshness. A legitimately absent source needs an explicit checked-absence record from its owner; two omitted, null or empty stamps are unknown, not current.
Retain its pointer for diagnosis, fetch the canonical evidence, and obey the
existing gate's failure behavior. A current packet can still have unknown
evidence; it is then an index for retrieval, not authority to proceed past it.

Recheck stop controls, claim, quota/budget and runtime capabilities immediately
before dispatch through their owning workflows. A packet cannot renew/take a
claim, declare another session dead, relax permissions, waive independent review,
check AC, certify green CI, close an issue or authorize a merge.

## Coordination walkthroughs

Sanitized inputs and expected dispositions live in
`.claude/scripts/tests/fixtures/task-packets/walkthrough.json`; run
`bash .claude/scripts/tests/task-packet-design.test.sh`. The test exercises the
proposed index/freshness/footprint decisions offline. It neither calls GitHub nor
acquires/releases real claims, edits worktrees, launches workers or merges PRs.

1. **Two overlapping issues:** different live holders and separate clean
   worktrees can still both declare `src/shared.py`. Existing same-batch overlap
   policy serializes them. Two independent batches can miss each other before
   either PR exists; the packet records both declarations without pretending to
   hold an atomic cross-thread file lock. Refresh/replan on changed scope.
2. **Two disjoint issues:** `src/parser.py` and `docs/guide.md` map to different
   surfaces. The packet permits parallel *planning* subject to live claim,
   capacity and stop controls and normal dispatch gates; it grants no extra slot.
   Two different rule files are deliberately a negative control: both map to
   `rule-corpus`, so they are not disjoint.
3. **Interrupted/resumed work:** packet points to the prior failed investigation,
   discoveries and pending next action. Refresh live ownership/adoption using
   `candidate-ownership.sh` and the existing resume route; rebuild against the
   actual worktree HEAD/current phase. A cheaper replacement loads the discoveries
   and active module, not the whole prior transcript. Old-HEAD test evidence
   remains unknown until rerun or verified for the new HEAD; unrelated modules
   and historical phases stay unloaded.
4. **Owner or source drift:** a new holder, changed issue AC, changed module or
   changed handoff/session invalidates the corresponding binding. Stop/retrieve
   rather than using an apparently fresh timestamp as authority. Unknown claim
   or worktree liveness never authorizes adoption or cleanup.

## Incremental implementation plan

1. **Read-only assembler pilot:** construct this index from existing scoped
   owners for one issue→phase handoff, with byte/list bounds, revision stamps,
   complete AC retrieval and explicit unknowns. Add no background scheduler or
   new tracker. Validate real packet sizes and retrieval latency before tuning.
2. **One caller/resume adapter:** persist only the index pointer through existing
   session/handoff helpers. Exercise interrupted resume, stale HEAD, changed
   owner, missing evidence and Issue #1875 attempt-history recovery before
   broadening to other callers. Retain every independent dispatch/review gate.
3. **Only demonstrated coordination gaps:** separately assess first-acquisition
   winner enforcement, without duplicating renewal. A reread/refusal can narrow
   the race but cannot provide distributed mutual exclusion after the read.
   Extend same-batch footprint declarations/scope refresh only where observed
   cross-thread collisions justify it; any proposed reservation must state its
   atomic owner, expiry, release and residual races. Existing local CAS is not
   a distributed GitHub-plus-worktree transaction.

This issue ends at the design and fixtures. The steps above are a future
implementation sequence, not a claim that an assembler or distributed lock has
shipped. No additional issue or external platform is required to record this
sequence. Choose a platform only after a measured gap demonstrates its advantage.
