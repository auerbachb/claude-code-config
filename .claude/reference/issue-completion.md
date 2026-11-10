# Verified issue completion after merge

A merged PR and a released claim do not prove that an issue is complete or CLOSED.
This procedure belongs to the shared workflow and runs from consumer repositories
as well as claude-code-config. It is completion reconciliation, separate from
`/pm-clean`'s confirmation-gated age/staleness cleanup.

## Entry points and evidence

Run after a normal or clean-BEHIND merge, on `/wrap`'s already-merged entry,
after Phase C returns, and when PM resumes or a day tick observes a tracked PR
has merged. Resolve `issue-completion.sh` through the usual installed-skills,
user-scripts, local-scripts order. Keep the working directory in the consumer
repo. Bind `OWNER_REPO`, PR and issue identities from the current task and the
verified GitHub PR; never infer them from the helper's checkout, a bare foreign
issue number, or the shared session state's flat numeric keys.

The helper is GitHub.com-specific. An explicit repository is mandatory; no default
repository is read from its own checkout. It emits JSON and writes private,
repo/PR-scoped receipts under `~/.claude/issue-completion/`. It performs no close
by default:

```bash
"$ISSUE_COMPLETION_SH" --repo "$OWNER_REPO" --pr "$PR_NUM"
```

Check the exit status and JSON together. Exit 0 means `outcome: verified` for
independently observed CLOSED issues or a verified no-issue delivery, or
`outcome: retained` for deliberate retention. A retained issue can be OPEN.
Exit 1 is pending completion, 3 is unverified or ineligible identity/scope,
4 is an API/response failure, and 6 is unsafe or unavailable local receipt
state. Usage errors exit 2. A missing helper or unreadable state is pending.
The receipt records fixed status and public identities; raw issue bodies,
credentials, and private task content are not copied into it.

A merged delivery with genuinely no associated issue is distinct from an unknown
or malformed association. Verify its task/handoff, title, body and related work;
only when none names a primary/partial issue, assess with --no-issue-verified and
--expected-merge bound to the verified merge SHA. This read-only explicit
disposition emits verified with no_associated_issues and allows final publication.
It refuses any linked issue or a simultaneous explicit primary-issue assertion.
An empty closing-reference list alone remains pending; it never proves there is
no issue, and does not authorize silently skipping a missing trailer.

## Verify scope before closing

For each OPEN same-repo candidate, independently read the issue's current body,
acceptance criteria and comments, the associated PRs and final merged code.
Capture the issue’s GitHub `updatedAt` when you start verifying scope, then
read it again after checking the evidence. If it changed, recheck the scope.
Record that revision, the criterion-by-criterion evidence and the disposition
in the current task’s scoped completion or handoff evidence. A checked PR Test
Plan alone is insufficient: a PR may deliver only a slice of the issue.

Keep an issue OPEN when any acceptance scope remains, another associated PR is
outstanding, an owner decision is unresolved, or completion cannot be verified.
A finished child does not close its parent/tracker. `Refs #N` and title mentions
are context, not closing instructions. Foreign references are retained as foreign;
do not strip their repository qualifier or act on the same number locally.
A deliberately reopened issue is retained when its reopen event is at or after
the merge; use a subsequent verified fix rather than replaying an old closure.

After full scope verification, automatically reconcile the single issue whose
closing link GitHub recognizes. Bind the request to the merged commit and the
issue revision from the scope evidence:

```bash
"$ISSUE_COMPLETION_SH" --repo "$OWNER_REPO" --pr "$PR_NUM" \
  --complete-issue "$ISSUE_NUM" --expected-merge "$MERGE_SHA" \
  --expected-issue-updated-at "$VERIFIED_ISSUE_UPDATED_AT" --scope-verified
```

`--scope-verified` is an assertion that the agent has performed and recorded all
checks above. It is never synthesized from PR MERGED, claim release, a title,
a closing trailer or a passing PR Test Plan. Run the write only for the
current tracked delivery. Backlog and consumer audit scans are read-only. The
helper also requires the PR to be authored by the authenticated account and
merged into the repo's current default branch. Non-default merges remain pending for default-branch delivery.

A missing or malformed closing link leaves the issue open. GitHub must identify
the same repository and exact issue in `closingIssuesReferences`. An explicit
association can support a read-only retained disposition, such as a partial
delivery documented in its handoff. It cannot authorize an automatic close.

The helper saves closure intent before requesting the single issue closure,
then independently reads the typed issue back. A write response alone is not
success. Already-CLOSED issues are idempotent and receive no duplicate close.
Other OPEN/foreign linked issues remain pending even when the selected issue
closes successfully. API failures, delayed visibility and interrupted requests
retain a retryable receipt and never become verified completion.

A PR-scoped private race guard is armed before each close request. All assessment,
retention and close modes share the PR lock and honor that guard. After an
interruption, a typed CLOSED read with no post-merge reopen can recover an
in-flight write without another close. A detected reopen becomes a sticky
`reopen_detected` hold: retries and ordinary assessments remain pending even if
the close request overwrote the owner's OPEN state. A malformed/unsafe guard is
also pending. Do not delete or rewrite that evidence to clear Phase C; preserve
it for an explicit owner decision or a separately verified subsequent fix.
GitHub does not offer an atomic conditional issue close. A simultaneous
manual reopen can still race the request. Report a detected conflict as
pending and preserve the evidence for manual resolution.

## Deliberately retained issue scope

A partial delivery, owner-held decision or intentionally reopened issue can
finish its PR wrap while the issue stays OPEN. After independently reading the
current issue/PR/task scope, record remaining work in scoped task evidence and
explicitly assess that disposition, pinned to the verified merge:

```bash
"$ISSUE_COMPLETION_SH" --repo "$OWNER_REPO" --pr "$PR_NUM" \
  --expected-merge "$MERGE_SHA" --retain-issue "$ISSUE_NUM=partial_scope"
```

Allowed fixed reasons are `partial_scope`, `owner_decision` and `reopened`.
Repeat `--retain-issue` for each deliberately retained same-repo issue; every
other linked issue must already be CLOSED or the result stays pending. A missing
trailer requires explicit `--association-verified` after verifying the task's
primary association. Foreign references stay pending for separate scoped
reconciliation. This read-only mode independently verifies each selected typed
issue and produces `outcome: retained` with public `retained_scope` identities
and fixed reasons. It never closes an issue or treats API failures, malformed
associations or incomplete assertions as retained. Do not use it merely to clear
a failed automatic closure. Pass these flags through the canonical adapter;
its successful report can then be published by the guarded handoff function.

## State, resume and handoff

Use this canonical adapter for each assessment or individually verified write.
It preserves the helper receipt and scopes PM bookkeeping to the invoking repo;
a failed state write cannot clear a pending action. `PR_NUM` and `OWNER_REPO`
come from the verified task identity, never from shared numeric-key inference.
Call it without extra arguments for assessment, or pass the explicitly verified
single-issue flags shown above. Its JSON remains in `COMPLETION_JSON` for scope
review and retained-work disposition.

<!-- test-anchor: issue-completion-record -->
```bash
reconcile_issue_completion() {
  local completion_helper completion_state completion_repo completion_write_rc=0
  COMPLETION_JSON=''; COMPLETION_RC=1
  [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]] || return 2
  completion_helper=$(resolve_script issue-completion.sh || true)
  completion_state=$(resolve_script session-state.sh || true)
  if [[ -z "$completion_helper" || -z "$completion_state" ]]; then
    echo 'ERROR: completion helper/state unavailable — issue completion pending' >&2
    return 6
  fi
  completion_repo=$("$completion_state" --repo-key) || return 6
  if [[ "$completion_repo" != "$OWNER_REPO" ]]; then
    echo 'ERROR: completion repository mismatch — state unchanged' >&2
    return 3
  fi
  COMPLETION_RC=0
  COMPLETION_JSON=$("$completion_helper" --repo "$OWNER_REPO" --pr "$PR_NUM" "$@") || COMPLETION_RC=$?
  if ! printf '%s' "$COMPLETION_JSON" | jq -e --arg repo "$OWNER_REPO" --argjson pr "$PR_NUM" \
      'type == "object" and .owner_repo == $repo and .pr == $pr and (.outcome == "verified" or .outcome == "pending" or
       (.outcome == "retained" and .error_class == null and (.retained_scope | type == "object" and length > 0)))' >/dev/null; then
    COMPLETION_JSON=$(jq -cn --arg repo "$OWNER_REPO" --argjson pr "$PR_NUM" \
      '{owner_repo:$repo,pr:$pr,outcome:"pending",error_class:"completion_report_unreadable"}')
    COMPLETION_RC=4
  fi
  "$completion_state" --set ".prs[\"$PR_NUM\"].issue_completion=$COMPLETION_JSON" || completion_write_rc=$?
  if [[ "$completion_write_rc" -ne 0 ]]; then
    echo 'ERROR: completion state write failed — preserve receipt and handoff' >&2
    return 6
  fi
  return "$COMPLETION_RC"
}
```


Keep the merged PR identity separate from issue completion. A merged PR must not
return to code dispatch or be merged again merely because closure is pending.
Record the receipt path and exact pending issue/reason in the current repo's
scoped PR/task state, using `session-state.sh`'s normal repo scoping. When GitHub
is already CLOSED, reconcile only the matching task's status/queue entry and
exact owned claim. Do not rewrite unrelated tasks or another repo's same number.

Retry the assessment and any individually verified completion on resume/day tick,
including a session interrupted after merge or after the close request. A stale
scope assertion is not authorization to close newly added work: reread current
criteria/comments and open associated work before retrying a write. A confirmed
CLOSED issue needs no second close, only scoped state reconciliation.

Phase C reports `OUTCOME: merged` only after both GitHub merge verification and
completion reconciliation are recorded. A merged PR with unresolved closure is
`OUTCOME: blocked`, with an explicit `PR already merged; completion pending`
reason and receipt path. The parent preserves the handoff/retry evidence and
runs completion recovery; it must not launch another code/review/merge pipeline
for the already-merged PR. Delete the handoff only after reconciliation or after
recording an explicitly justified retained issue with its remaining work.

After the full wrap is finished, Phase C publishes its final completion report
into the existing scoped handoff before returning merged. The report must match
the verified repo/PR/HEAD. Retained scope requires recorded remaining work and
no API/error result; it cannot disguise an unknown closure failure. Publish the
disposition first and Phase C last, so interruption leaves an incomplete handoff.
Do not stamp completion at the start of wrap or merely when the close API returns.
Parent cleanup and artifact sweeps retain pending, legacy and active handoffs;
the workspace sweep independently verifies owner inactivity.

<!-- test-anchor: issue-completion-publish -->
```bash
publish_completed_handoff() {
  local completion_handoff
  [[ "$PR_NUM" =~ ^[1-9][0-9]*$ && "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || return 2
  if ! printf '%s' "$COMPLETION_JSON" | jq -e --arg repo "$OWNER_REPO" --argjson pr "$PR_NUM" --arg head "$HEAD_SHA" \
      '.owner_repo == $repo and .pr == $pr and .head_sha == $head and .error_class == null and
       (.outcome == "verified" or (.outcome == "retained" and (.retained_scope | type) == "object" and (.retained_scope | length) > 0))' >/dev/null; then
    echo 'ERROR: final completion disposition unverified — handoff retained' >&2
    return 3
  fi
  completion_handoff=$(resolve_script handoff-state.sh || true)
  [[ -n "$completion_handoff" ]] || return 6
  "$completion_handoff" --owner-repo "$OWNER_REPO" --require-existing \
    --expect-pr "$PR_NUM" --expect-owner "$OWNER_REPO" --expect-head "$HEAD_SHA" \
    --set "$PR_NUM" ".issue_completion=$COMPLETION_JSON" || return $?
  "$completion_handoff" --owner-repo "$OWNER_REPO" --require-existing \
    --expect-pr "$PR_NUM" --expect-owner "$OWNER_REPO" --expect-head "$HEAD_SHA" \
    --set "$PR_NUM" '.phase_completed="C"'
}
```

An intentionally partial issue is not an error to "repair": record its retained
scope and outstanding delivery, release only the exact completed PR's owned
claim when appropriate, and preserve the remaining issue in the backlog. Do not
silently mark the whole issue done. An API/verification error stays actionable;
never relabel it as an intentional partial disposition to clear the workflow.

## Investigation and consumer audit

Issue #1973 concerns consumer repos using the shared skill, especially sales-kit.
The config repo's bounded control sample (100 merged PRs, 101 closing-linked
issues, all CLOSED) did not reproduce the report. The consumer audit examined
100 merged sales-kit PRs and 98 distinct typed closing/title references. Eight
referenced issues remained OPEN. Several are expressly partial deliveries;
merged association alone must not close them.

Additional consumer controls: 50 merged inventory PRs yielded 32 typed references,
and 50 merged still-point PRs yielded 50; all referenced actual issues were
CLOSED. No foreign closing references occurred in these three samples.

The concrete mismatch is sales-kit Issue #2214 and PR #2239. The PR merged to
default `main` on 2026-11-04T21:22:58Z, merge commit
`07c2821fdd1cded81b8d135c0c99015a3afab071`. Its current body carries a recognized
`Closes #2214`, but the issue remained OPEN with no closed/reopened timeline
event. The exact body at merge time is not independently captured. Later
Issue #2398/PR #2400 delivered additional timing scope, so live recovery requires
current full-scope verification, not retrospective trust in the first PR.

The supported workflow cause is missing independent post-merge verification and
recovery: `/wrap` released claims without reading CLOSED, already-merged entry
skipped post-merge work, and PM hygiene only flagged missed closure as shared
state drift. These gaps permit the observed mismatch to survive. They do not
prove why GitHub itself failed to auto-close that issue.

No recent removal of a deterministic closure step was found: the initial wrap
commit `6a317595` (2026-03-29) already lacked it. An earlier successful manual/API
fallback control is config PR #1750 / Issue #1748: PR merged without closing
references on 2026-10-01T21:05:40Z, issue closed 189 seconds later. The actor/path
of that fallback is unknown. Therefore the supported observation window is
working fallback on October 1 to a missed consumer closure on November 4;
repository/path differences prevent claiming a causal regression commit.

Audit dispositions must remain explicit. Partial sales-kit Issues #2373, #860,
#859, #2321, #2322, #2159 and owner-maintained #13 remain open until their own
criteria/decisions are satisfied. Issue #2214 remains pending full current coverage verification: its criterion 6
requires documentation that current authority §7.2 does not provide. That section
still dedicates the control-change credential to control changes; the merge
comment explicitly said it was untouched under the owner’s decision. Reconcile
that criterion/decision in the consumer chat before claiming full completion. No consumer code or issue state was changed
by the read-only investigation.
