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

Observed with `codeant` v0.5.1 and `coderabbit` v0.6.5 on 2026-07-21.

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
records — reviewed nothing, regardless of exit code. Check for a terminal `type: "error"`
record before treating absence of findings as a clean pass:

```bash
coderabbit review --agent >cr.out 2>cr.err
jq -e 'select(.type=="error")' cr.out >/dev/null && echo "FAILED RUN - not a clean pass"
```

`metadata.waitTime` gives the cooldown. Per `cr-local-review.md`, a rate-limited CLI is a
dropped CLI for the session — note it in the PR body; do not retry more than once.

Related: a CodeRabbit *GitHub* check-run can report `success` while its description says
"Review rate limited" — read the description, not the state.

## CodeAnt auth storage

`codeant login` is a browser flow (prints a URL, polls every 10s, 10-minute timeout) and
stores the key as `apiKeyV2` in `~/.codeant/config.json`. `codeant logout` nulls that field
but leaves the key present in the file. Never print or commit the value — inspect shape only:

```bash
jq 'map_values(if type=="string" then {length:length} elif .==null then "NULL" else type end)' ~/.codeant/config.json
```
