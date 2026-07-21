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

## Classifying a 403: entitlement vs credentials

The CLI's 403 text always says to re-authenticate. **That advice is often wrong.** A 403 is
authorization, not authentication, and a valid token can still be denied.

Probe before re-authenticating:

```bash
codeant scans orgs     # valid token -> returns {"connections":[{"organizationName":...}],"email":...}
```

| `scans orgs` | `review` | Diagnosis |
|---|---|---|
| OK | OK | Healthy |
| OK | 403 | **Entitlement / plan / quota.** Do not re-authenticate — it will not help. Check the account plan at app.codeant.ai. |
| 403 | 403 | Credentials. `codeant logout` then `codeant login` (browser flow). |

Corroborating probes when `scans orgs` succeeds but `review` does not:

- `codeant settings repos` — confirms the repo is onboarded (rules out repo-level cause)
- `codeant secrets --last-commit` — a different feature on the same token; if it runs, the
  token is broadly fine and the denial is specific to the review feature
- Run `review` in a second onboarded repo — same 403 in both means account-level, not repo-level

Worked example (2026-07-21, `auerbachb`): `scans orgs` returned the org and account email,
`settings repos` listed 63 onboarded repos, `secrets` ran clean, and `review` returned 403 in
two different repos. `logout` + `login` completed successfully and installed a fresh token;
the 403 was unchanged. Root cause was account entitlement, not credentials.

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
