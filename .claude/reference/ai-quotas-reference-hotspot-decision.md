# Quota reference hotspot decision

Issue #1720. The untruncated default-branch detector after PR #2077 counted 15 changes to `.claude/reference/ai-quotas.md`, with score 15 and no recorded conflict re-resolutions.

KEEP one quota reference. Its setup, usage, history, and recovery sections share the same account schema and source restrictions. The quota skills already link to specific sections. Keep those entry points and add short navigation so callers can find the applicable contract without reading the entire file.

| Counted PRs | Reference area |
|---|---|
| #1852, #1891, #1931, #2004, #2068 | Setup, profile layout and recovery. |
| #1865, #1868, #1890, #1905, #1986, #1999 | Resets, usage windows, reserve, and account history. |
| #1896, #1964, #1994, #2002 | Source fallback, relogin, and browser diagnosis. |

The original report's #1683, #1689, #1695, #1704, #1705 and #1711 are separate verified historical changes. They are outside the current count.

The strongest split would move the operational recovery runbook away from the configuration and reader contracts. Revisit that if another workflow needs to load it independently or if repeated conflicts show unrelated setup and recovery edits competing in the same section. Preserve stable section links and keep the display-only and reserve boundaries in their present authority.

## Superseded by Issue #2180 (2026-11-19)

The KEEP decision above no longer holds. The file grew to about 19,000 words with 17 merged PRs in 60 days, a run needing one fact had to read all of it, and quota issues queued on one document. Issue #2180 split it by topic, following the provider-library seams of Issue #2179:

| File | Holds |
|---|---|
| `ai-quotas.md` | Overview and index: registry schema, profile layout, credentials, helper contract, the reserve consumer, and a topic map. |
| `ai-quotas-reader.md` | The shared reader contract, overage, the read-outcome ledger, ordered usage sources, last-known folder, FETCHED, paid usage and plan tier. |
| `ai-quotas-claude.md`, `ai-quotas-codex.md`, `ai-quotas-cursor.md` | One file per provider reader. Token renewal sits with the Claude reader. |
| `ai-quotas-history.md` | The history file, the daily job, nicknames and burn-rate projection. |
| `ai-quotas-setup.md` | Re-login commands, launchers and shared config, label/path repair, fresh-profile reauthentication, export/import. |

Link preservation: sections moved verbatim, in original order, with only navigation-only edits (cross-file links where a sentence said "above", "below" or "this file"). Every known consumer was retargeted to the new file and fragment; no stub headings were left at the old fragments. The display-only and reserve boundaries stay authoritative in `ai-quotas.md`, and each topic file links back to it.
