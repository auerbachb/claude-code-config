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
