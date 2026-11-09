# Quota setup skill hotspot decision

Issue #1918. The untruncated default-branch detector after PR #2062 counted six changes to the entry, with score 6 and zero recorded conflict rounds.

## Decision

KEEP `/quotas-setup` as a single entry. The capabilities below share a routing table, the registry boundary, and the stop conditions that protect active profiles. Splitting procedures into separate references would leave the routing changes in place and make the shared stop conditions easier to miss.

| Merged PR | Contribution |
|---|---|
| [PR #1852](https://github.com/auerbachb/claude-code-config/pull/1852) | Added launcher and configuration sharing routes and steps. |
| [PR #1891](https://github.com/auerbachb/claude-code-config/pull/1891) | Added diagnosis and repair for mismatched profile layouts. |
| [PR #1896](https://github.com/auerbachb/claude-code-config/pull/1896) | Added source preference and fallback guidance. |
| [PR #1905](https://github.com/auerbachb/claude-code-config/pull/1905) | Added account ledger and project history guidance. |
| [PR #1964](https://github.com/auerbachb/claude-code-config/pull/1964) | Put relogin first for logged-out accounts and added daily notices. |
| [PR #2004](https://github.com/auerbachb/claude-code-config/pull/2004) | Documented fresh-profile recovery and the failed-repair report boundary. |

## Verified wording corrections

The existing private setup fixtures passed 547 checks on both macOS Bash 3.2 and current Bash. The helper derives status from credential presence, uses stored profile paths, and can retain the old launchd definition after installing a new plist. Its sharing race check runs before backing up and replacing `.claude.json`; earlier items can already have changed. A private fixture wrote after the backup and the replacement overwrote that later value on both Bash versions, so the docs require an idle profile rather than promising that the check prevents all races. MCP values survive JSON reserialization. A refused registry write does not undo an earlier provider login.

Correct those descriptions in the two existing documents while keeping the routing, all safety checks and the helper unchanged. No owner profile or login was touched.

Revisit extraction if a separate reader emerges or the current routing or safety sections show measurable conflict or maintenance cost. The exact Issue #1918 baseline is score/count 6; the existing 2× material-growth rule still applies.
