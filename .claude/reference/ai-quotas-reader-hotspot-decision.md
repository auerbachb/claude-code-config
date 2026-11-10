# Quota reader hotspot decision

Issue #1950. The untruncated default-branch detector after PR #2067 counted ten changes to `.claude/scripts/ai-quotas.sh`, with score 10 and no recorded conflict re-resolutions. The three changes from the original report (#1865, #1890 and #1896) are all in this count.

KEEP the quota reader's dispatch and provider adapters together for now. The entry point owns the ordered source chain, bounded attempts, normalized rows, and the report and outcome ledger. Keeping source choice and these side effects in one place makes it possible to verify that an intermediate attempt cannot publish a final row or suppress its fallback. Claude, Codex and Cursor retain different authentication and read paths.

| Counted PRs | Why they touched the reader |
|---|---|
| #1865, #1986, #2067 | Codex reset credits, HTTP window decoding, and app-server process cleanup. |
| #1890, #1896 | Attempt outcomes and ordered provider source fallback. |
| #1964, #1981 | Relogin guidance and scheduled notification, and date capability detection. |
| #1994, #2002, #2007 | Browser failure diagnostics, completed browser evidence, and Cursor token-store diagnosis. |

The strongest extraction candidate is the Codex app-server transport: FIFO requests, the verified process group, and cleanup of owned descendants can form a narrow boundary. It currently has one production caller and is exercised with real local fixture processes. Split it if another production caller needs that transport or if recurring conflicts show that transport changes repeatedly collide with unrelated reader work. Keep source order, interpretation of failed attempts, and publication in the reader even if transport moves. No credential, provider, or report behavior changes here.
