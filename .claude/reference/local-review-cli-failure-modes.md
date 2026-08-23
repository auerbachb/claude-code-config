# Local Review CLIs — Failure Modes

Diagnostic detail behind the NON-NEGOTIABLE check in `.claude/rules/cr-local-review.md`
("A 'clean' result may be a failed run"). That rule owns enforcement; this file explains
what the failures look like and how to classify them.

**Both CLIs exit `0` on total failure, and each hides the error on a different stream.**
Checking one stream catches one CLI and misses the other:

| CLI | Exit | Failure appears on | Looks like |
|---|---|---|---|
| CodeAnt | `0` | **stderr** | `API Error` / `[error] Failed to review`; stdout JSON stays `{"issues": []}` |
| CodeRabbit | `0` | **stdout** | NDJSON record `{"type":"error","errorType":"rate_limit",...}` |

Observed with `codeant` v0.5.1 and `coderabbit` v0.6.5 on 2026-07-21. CodeRabbit v0.7.5 confirmed at `~/.local/bin/coderabbit` on 2026-08-23.

## Measured throughput and current CLI state (2026-08-23, issue #1286)

This section records observed behavior rather than vendor-published figures. Vendor numbers live in
`pricing-matrix.md`.

**Representative window: 2026-08-22 session, PR #1265**

| CLI | Attempts | Successful reviews | Failure mode |
|---|---|---|---|
| CodeRabbit CLI | 1 | 1 (sole coverage) | None — completed, `cr-only` result recorded |
| CodeAnt CLI | 2 (initial + 1 retry per `cr-local-review.md`) | 0 | 403 on both invocations: daily cap (auth was present; quota exhausted) |

Coverage for PR #1265: `cr-only` (CodeAnt dropped after one retry per `cr-local-review.md`).

**Measured on 2026-08-23 (this investigation, issue #1286)**

| CLI | Run | Result | failure_mode | Observations |
|---|---|---|---|---|
| CodeRabbit CLI | 1st | `verified_run: true`, 4 findings | — | Successful, 176s, free OSS pool confirmed |
| CodeRabbit CLI | 2nd (retry after fixes) | `verified_run: false` | `error_record` | Rate-limited; `isProUser: false`; 3 OSS reviews used; 55-min wait |
| CodeAnt CLI | 1st | `verified_run: false` | `stderr_error` | 403 on review endpoint; `scans orgs` = "Missing API key" → no credentials |

Coverage for this investigation PR: `none` — CodeRabbit rate-limited after first run; CodeAnt unauthenticated. Self-review applied.

**Current CLI state (2026-08-23)**

| CLI | Binary location | Version | Auth state | Expected result on next run |
|---|---|---|---|---|
| CodeRabbit | `~/.local/bin/coderabbit` | 0.7.5 | `Plan: Pro / Seat: assigned` (auerbachb, org: LocalMovers-dot-com) | OSS pool applies on this public repo: 1–10/hr (repository-popularity scaled), NOT the Pro tier's 5/hr. Entitlement ≠ effective rate. See pricing-matrix.md §5. |
| CodeAnt | `/opt/homebrew/bin/codeant` | 0.5.1 | **No credentials** — `~/.codeant/config.json` absent | `stderr_error` / `verified_run: false` on any non-empty diff |

**Key finding — CodeRabbit rate limit payload (captured 2026-08-23, second CLI run):**

```json
{
  "type": "error", "errorType": "rate_limit",
  "metadata": {
    "isProUser": false,
    "waitTime": "55 minutes",
    "policyGuidance": "You've used all 3 included reviews currently available. … public repository.",
    "orgAttributed": false,
    "onDemandReviewAvailable": false
  }
}
```

The rate-limit payload also carries the message "This looks like a public open-source repository.
CodeRabbit will review it for free, and no organization will be billed. Free OSS limits apply."
This is emitted by the CLI itself when it detects a public repo, before any API call. The
payload confirms: `isProUser: false` = OSS billing pool; 3 reviews included in the reset
window (~55 minutes); the Pro account's 5/hr allowance is NOT drawn here. This reconciles
the apparent contradiction between `auth status` ("Plan: Pro, Seat: assigned") and the
rate-limit payload (`isProUser: false`): the account has a Pro seat, but this specific repo
is routed through the free-OSS pool, which has its own 3/hr cap.

**Key finding:** `local-review.sh` checks `/opt/homebrew/bin/coderabbit` first and `~/.local/bin/coderabbit`
second. CodeRabbit is only at the second path. The script finds it correctly (no breakage), but
the binary is not at the expected primary location. If `/opt/homebrew/bin/coderabbit` appears in
a future Homebrew install, it would shadow the current version.

**What the pipeline should do when both CLIs are unavailable:** `cr-local-review.md` already states
this: "If both CLIs are down, run a self-review instead." Self-review exits the local loop but
never satisfies the merge gate — the merge gate requires a GitHub-App approval (CodeRabbit App,
CodeAnt App, BugBot, or Greptile). A `none`-coverage local pass with self-review is correctly
reported in the PR body and does not block merge; the GitHub App side is a separate billing
surface and was unaffected by both CLI failures on 2026-08-22.

## CodeAnt CLI not installed (issue #819)

This is the third, simplest CodeAnt failure state — the binary is absent entirely. It is distinct from the false-clean (#642) and 403 daily-cap (#643) states: there is no API call to fail, no stderr error, and no ambiguity. The only signal is a shell error before any review runs.

| Signal | Value | Usable? |
|---|---|---|
| Shell exit code | non-zero (`127` on most shells) | Yes — `codeant: command not found` |
| stderr | `command not found: codeant` (or similar) | Yes — unambiguous before any API call |
| stdout JSON | (none) | N/A |

**Contrast with the other two states:**

| State | Binary present? | API call made? | stderr signal |
|---|---|---|---|
| Not installed (#819) | **No** | No | `command not found` before any review |
| False-clean (#642) | Yes | Yes (fails silently) | `API Error` / `[error] Failed to review` on stderr |
| 403 daily-cap (#643) | Yes | Yes (quota exhausted) | 403 text on stderr; token is fine |

**Rung-1 evidence shape.** When checking for the binary, probe absolute paths — the Bash tool's minimal PATH makes a bare `which` unreliable:

```bash
for p in /opt/homebrew/bin/codeant ~/.local/bin/codeant ~/bin/codeant /usr/local/bin/codeant; do
  ls "$p" 2>/dev/null && echo "FOUND: $p" || true
done
npm list -g codeant-cli 2>/dev/null
```

**Coverage-enum mapping:** CodeAnt `command not found` / not installed → CodeAnt **not covered** → `cr-only` coverage (see table below).

**Restore path (capability-ladder rung 3 → 5).** The package name `codeant-cli` is confirmed in this doc and in `.claude/reference/codeant-graphite-supplemental.md`. Install is non-interactive and satisfies all rails (no `curl|sh`, no TLS bypass, no `sudo` required at the Homebrew npm prefix):

```bash
npm install -g codeant-cli   # rung 3 — installs the binary
codeant login                 # rung 5 — CLI-initiated browser OAuth; no MCP browser surface can drive it
```

Auth (`codeant login`) opens a browser flow against `app.codeant.ai` and is the only blocker for a non-interactive agent. Full runbook with Option B (API key) and the proof-run stderr check: `.claude/reference/codeant-graphite-supplemental.md` §Install state. Ladder definition: `.claude/rules/safety.md` §Capability Discovery.

**Standing state on this machine:** binary installed (v0.5.1 at `/opt/homebrew/bin/codeant`). Auth present through at least 2026-08-22 (PR #1265 hit a 403 daily cap, which requires a live token). As of 2026-08-23, `~/.codeant/config.json` is absent — no credentials stored. Coverage is `cr-only` or `none` until `codeant login` or `codeant set-codeant-api-key` is run interactively. See "CodeAnt: missing API key" section below for the full diagnostic.

## The false-clean

On total API failure, `codeant review` produces a result that is indistinguishable from a
clean review on every channel an agent would normally check:

| Signal | Value on total failure | Usable? |
|---|---|---|
| Exit code | `0` | No — `if codeant review ...; then` reads as success |
| stdout `issues` | `[]` | No — identical to a genuine clean pass |
| stdout `meta.reviewed_files` | every file listed | No — means *attempted*, not reviewed |
| stdout `meta.skipped` | `[]` | No |
| stdout `meta.capped` | `false` | No |
| **stderr** | `API Error` / `[error] Failed to review` | **Yes — the only signal** |

There is no failure field anywhere in the JSON. The canonical agent invocation
`codeant review --all --headless > out.json` discards stderr, leaving `out.json` a clean,
self-consistent lie. Any check that reads only the JSON can never detect this.

Real captured stderr from a 6-file run where zero files were reviewed:

```
[files] Reviewing 6 file(s)
API Error: Access denied (403). Please run `codeant logout` and then `codeant login` to re-authenticate.
[error] Failed to review services/insight-service/src/...: Access denied (403). ...
[progress] 0 files have suggestions, running reflector...
```

Note `[progress] 0 files have suggestions` — the reflector runs and reports zero suggestions
even though nothing was successfully analyzed.

## Classifying a 403: the daily cap, not credentials

The CLI's 403 text always says to re-authenticate. **That advice is wrong, and following it is
actively harmful** — it cannot fix a quota, it nulls the stored token, and it throws a browser
login page at the user. On repeat it becomes an endless loop.

The real cause is an **undocumented daily cap on CLI agent reviews**. The server says so plainly;
the CLI discards the message (see `fetchApi.js` above). Read it yourself by replaying the request
— never echo the token:

```bash
TOK=$(jq -r '.apiKeyV2' ~/.codeant/config.json)
curl -sS -w '\nHTTP %{http_code}\n' -X POST \
  'https://service.codeant.ai/extension/pr-review/agent/turn' \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"diff_content":"diff --git a/t.js b/t.js\n+const b=2;\n","file_content":"const b=2;\n","file_path":"t.js"}'
```

Observed 2026-07-21:

```json
{"error":"Unable to process request. Either the API key is invalid or the daily limit of 10 for agent review has been reached."}
```

**That message names two causes with opposite remedies, so it is not decisive alone.**
Discriminate with `codeant scans orgs`:

| `scans orgs` | `review` | Diagnosis |
|---|---|---|
| OK | OK | Healthy |
| OK | 403 | **Daily agent-review cap reached.** Token is fine. Do NOT re-authenticate. Drop CodeAnt for the session — the cap resets the next day. |
| 403 | 403 | Credentials. `codeant logout` then `codeant login` (browser flow). |

Further proof the request authorizes: a *minimal* payload to the same endpoint returns
`400 {"error":"session_id is required for subsequent turns"}`. A 400 means it reached body
validation, so auth and authorization both passed.

**One `codeant review` is not one unit.** `reviewHeadless.js` batches up to 5 files per turn loop
(`MAX_TURNS = 5`), then runs a reflector loop per file with suggestions, so one invocation issues
several `agent/turn` calls. Budget only a few reviews per day.

**The cap is invisible in the dashboard.** "AI Code Reviews: Unlimited" there describes the
**GitHub App** surface, which has a separate counter and keeps working normally — 234 runs on the
same day the CLI was locked out. The GitHub App also satisfies the CR-path merge gate on its own,
so a capped CLI is never blocking.

Corroborating probes when `scans orgs` succeeds but `review` does not:

- `codeant settings repos` — confirms the repo is onboarded (rules out repo-level cause)
- `codeant secrets --last-commit` — a different feature on the same token; if it runs, the
  token is broadly fine and the denial is specific to the review feature
- Run `review` in a second onboarded repo — same 403 in both means account-level, not repo-level

Worked example (2026-07-21, `auerbachb`): `scans orgs` returned the org and account email,
`settings repos` listed 63 onboarded repos, `secrets` ran clean, and `review` returned 403 in
two different repos. `logout` + `login` completed successfully and installed a fresh token; the
403 was unchanged — **twice**. Plan was Premium ACTIVE with a seat assigned and 234 GitHub App
reviews that same day. Root cause was the daily cap; every credential, seat, plan, and onboarding
hypothesis was a dead end.

## The 15-file cap

`meta.max_files` is `15`. On a larger change set:

- `meta.capped` becomes `true`
- files beyond the 15th land in `meta.skipped` with reason `exceeded 15-file limit`
- `issues` still reports `[]` for every skipped file

A capped run therefore looks clean for the untouched remainder. Reviewing a 40-file change in
one invocation yields real coverage of at most 15 files.

Workarounds:

- Scope with `--include` and run per directory or per service
- Split into multiple runs and union the findings
- Always read `meta.capped` and `meta.skipped` before treating a run as full coverage

## CodeRabbit: failure on stdout, exit 0

`coderabbit review --agent` emits NDJSON on stdout. On rate-limit exhaustion it exits `0`
with a **clean stderr** and signals the failure as a record in the stdout stream:

```json
{"type":"error","errorType":"rate_limit","message":"Rate limit exceeded","recoverable":true,
 "metadata":{"isProUser":true,"waitTime":"28 minutes","orgAttributed":true}}
```

A run that produced only `review_context` and `status` records — with no `review`/finding
records — reviewed nothing, regardless of exit code. The authoritative verdict is the
**terminal `type: "complete"` record**, which carries both the outcome and the count:

```json
{"type":"complete","status":"review_completed","findings":3,"reviewedFiles":["a.sh"]}
{"type":"complete","status":"review_skipped","findings":0,"message":"No changes detected"}
```

Its **absence** means the run died mid-flight — never read that as "no findings". And
`review_skipped` is not a clean pass: it means the CLI saw no changes at all, which is
usually a wrong-working-directory tell (memory `bash-cwd-resets-between-calls.md`).

`.claude/scripts/local-review.sh --tool coderabbit` checks all three (error record,
missing terminal record, `review_skipped`) plus the CodeAnt side, and returns the compact
contract. Hand-rolled equivalent, error record only:

```bash
coderabbit review --agent >cr.out 2>cr.err
jq -e 'select(.type=="error")' cr.out >/dev/null && echo "FAILED RUN - not a clean pass"
```

`metadata.waitTime` gives the cooldown. Per `cr-local-review.md`, a rate-limited CLI is a
dropped CLI for the session — note it in the PR body; do not retry more than once.

Related: a CodeRabbit *GitHub* check-run can report `success` while its description says
"Review rate limited" — read the description, not the state.

## The hang bound: idle, not elapsed (issue #1220)

`local-review.sh --timeout` bounds **silence**, not duration. Seconds with no byte written to
either capture; any write — a CodeRabbit `heartbeat` record included — resets it. The number
lives in the script and nowhere else, the way `bgwork-ceiling.sh` owns `CEILING_S_DEFAULT`;
`cr-local-review.md` says "the wrapper's idle bound" and names no value.

Wall-clock was the wrong instrument, and the measurements say so plainly — same repo, same
change set, back-to-back runs of the CodeRabbit CLI:

| Change set | Bound | Outcome |
|---|---|---|
| PR #1218, 5 files | `--timeout 120` (the old default) | killed at 123s, `failure_mode: "timeout"` |
| PR #1218, 5 files | `--timeout 300` | `ok: true`, 0 findings, **221s** |
| PR #1222, 2 large prose files | `--timeout 300` | killed at **304s**, still emitting heartbeats |
| PR #1222, 2 large prose files | `--timeout 900` | `ok: true`, 2 findings, **271s** |

The third row is the whole argument: at the moment it was killed that run was writing
heartbeat records, and the identical change set completed in 271s on the retry. Elapsed time
cannot separate a slow review from a wedged one. Output can.

**Why the default is 900.** It is ≥3× the longest observed successful review (271s), and the
margin is not arbitrary. Heartbeats are **sparse** — captured CR logs carry 2–8 per run, so
the bound has to clear a heartbeat *gap*, not a tick. Sampling this change set's own review
once a second (146 samples) showed the capture growing throughout, with a longest silent
stretch of **46s** — liveness is observable in real time, not only in hindsight. That run took
**150s**, so the old 120s wall-clock default would have killed the very review that proved the
fix works. It also has to stay safe for a CLI that
goes quiet mid-review: CodeAnt writes `[files]`/`[progress]` lines to stderr but its inter-line
cadence is unmeasured, and where a CLI is silent an idle bound degrades to a wall-clock one.
Erring high is cheap — the bound only caps a hang and costs nothing when the review finishes.
Erring low is not: it burns a review against the ~3-per-40-minutes free-OSS CLI cap
(`cr-cli-free-oss-tier-cap`) and drops a healthy CLI to degraded coverage.

**Why a second bound.** An idle bound cannot stop a CLI that emits output forever without
finishing, so `--max-duration` is the backstop — default `2 × --timeout`, derived rather than
published as a second literal so retuning one moves the other. Both bounds exit `4` with
`failure_mode: "timeout"`; `relevant_error` names which tripped. An explicit `--max-duration`
below `--timeout` is allowed and makes the ceiling dominate, leaving the idle bound unreachable.

**Reading a `timeout` verdict.** Check `log_path` for `heartbeat` records and a terminal
`complete`. Both present means the run was working and the bound was too tight for the change
set — retry with a larger bound rather than counting the CLI as dropped. `relevant_error` says
which one tripped: raise `--timeout` when it names the idle bound, `--max-duration` when it
names the ceiling. Raising the wrong knob leaves the run killed at exactly the same second.

## Coverage enum — mapping failure states

`cr-local-review.md` defines coverage as `both | cr-only | codeant-only | none`. A CLI contributes to coverage **only** when it produced a verified-successful clean pass. Failures map as:

| Failure state | Coverage contribution |
|---|---|
| CodeRabbit `rate_limit` NDJSON error record | CR **not covered** |
| CodeRabbit `type: "error"` (any `errorType`) | CR **not covered** |
| CodeRabbit emits only `review_context`/`status` records with no `review` or finding records | CR **not covered** |
| CodeAnt stderr API Error / 403 daily-cap | CodeAnt **not covered** |
| CodeAnt stderr API Error / missing API key (no `~/.codeant/config.json`) | CodeAnt **not covered** |
| CodeAnt `meta.capped == true` (15-file cap) | CodeAnt **not covered** (partial coverage is not full coverage) |
| CodeAnt `command not found` / not installed | CodeAnt **not covered** |
| CodeAnt false-clean (stderr error, stdout `{"issues":[]}`) | CodeAnt **not covered** |
| Either CLI trips a wrapper bound (`failure_mode: timeout`) or errors twice (dropped) | That CLI **not covered** |

Enforcement ownership stays in `cr-local-review.md`. This table only maps failure appearances to the enum.

## CodeAnt: missing API key — distinct from 403 daily cap (issue #1286)

Observed 2026-08-23: `~/.codeant/config.json` does not exist; `codeant get-codeant-api-key`
returns "No CodeAnt API key configured". This is a **different failure state from the 403 daily
cap** documented above — there is no stored credential at all, so every request that reaches the
API (i.e., every review invocation when there are files to review) fails immediately.

| Condition | What triggers | Detectable by local-review.sh? |
|---|---|---|
| 403 daily cap | `~/.codeant/config.json` exists with `apiKeyV2`; server rejects because quota exhausted | YES — `API Error: Access denied (403)` on stderr matches `CA_ERR_RE` |
| No credentials (no config file / null key) | `~/.codeant/config.json` absent; no auth header sent to server | YES — review endpoint returns **403** (same signal as daily cap); `API Error: Access denied (403)` on stderr matches `CA_ERR_RE` |

**Ambiguity:** both the daily cap and no-credentials paths produce the same 403 on the review
endpoint. The `codeant review --headless` exit code and stderr pattern are identical. The only
discrimination is the `scans orgs` probe:

```bash
# Run this BEFORE concluding the 403 is a daily cap
codeant scans orgs 2>&1
# OK → credentials valid → 403 = daily cap, reset tomorrow
# "Missing API key" / error → no credentials → restore with codeant login
```

Observed 2026-08-23: `scans orgs` returned "Missing API key" AND `review` returned 403 → **no
credentials**, not daily cap. The `review` endpoint returns 403 for both causes; only `scans orgs`
discriminates.

**One subtlety:** when `codeant review --all --headless` is called with no git changes to review
(e.g. because the worktree has no new commits), the CLI returns `noFiles: true` without
ever calling the API. In that case the missing-key failure is never triggered — `local-review.sh`
correctly classifies the result as `no_changes_reviewed` (exit 3, `verified_run: false`), not as
a false clean pass. If there ARE files to review, the API call is made and the auth failure
surfaces on stderr as documented above.

**False-clean detection coverage for the missing-key case:**
- stderr: `console.error("API Error: Missing API key")` from `fetchApi.js` → matches `CA_ERR_RE` → `stderr_error`
- stdout: `.error: "Missing API key"` in the NDJSON result → caught by the stdout `.error // empty` check (step 2)
- Both paths classify as `verified_run: false` — no clean-pass false positive.

**Restore path:** `codeant login` (browser OAuth, opens a URL and polls for completion) or
`codeant set-codeant-api-key <key>`. Both are interactive steps that cannot run in a
non-interactive agent session. Blocked until a human performs auth. Once auth is restored,
the daily cap (not the missing key) becomes the operative blocker again.

**Standing state (2026-08-23):** `~/.codeant/config.json` absent — no credentials confirmed
by `scans orgs` returning "Missing API key". Auth was present through at least 2026-08-22
(PR #1265's `cr-only` note confirms a daily cap, which requires a live token; the file must
have been deleted between that session and this investigation). The review endpoint also
returned 403 on 2026-08-23, but that 403 is an auth failure, not a cap — `scans orgs`
discriminates. Restore with `codeant login` or `codeant set-codeant-api-key`. Coverage
stays `cr-only` or `none` until auth is restored.

## CodeAnt auth storage

`codeant login` is a browser flow (prints a URL, polls every 10s, 10-minute timeout) and
stores the key as `apiKeyV2` in `~/.codeant/config.json`. `codeant logout` nulls that field
but leaves the key present in the file. Never print or commit the value — inspect shape only:

```bash
jq 'map_values(if type=="string" then {length:length} elif .==null then "NULL" else type end)' ~/.codeant/config.json
```

**Note on config deletion vs. nulling:** `codeant logout` is documented as nulling `apiKeyV2`,
not deleting the file. If `~/.codeant/config.json` is entirely absent (as observed 2026-08-23),
the likely cause is a manual file deletion or machine clean-up, not a `codeant logout` call.
The effect is the same — no credentials — but the discrimination matters for diagnosis.
