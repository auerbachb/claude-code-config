# Active-work cap fixture hotspot decision

Issue #1296. **Keep the active-work cap fixture together.** It uses one isolated repo and fake GitHub reader to check the effective cap, PRs, offers, pre-PR pipelines, and read failures. The offer cases also check that the registry and legacy log do not double-count. The cap and ceiling checks share the configuration contract with the dispatch cases, but both modes exit before reading count sources.

The original report counted #1224, #1250, #1252, and #1267, including fixture creation in #1224. The current window since October 26, 2026, contains one change: #1924 raised the supported bound and updated the cap and ceiling resolution checks independently. That one change falls below the detector's two-PR floor, with no recorded conflict cost.

Configuration resolution could run in a separate fixture without a fake count source. One independent update does not show a maintenance cost that warrants a second fixture or a shared helper. Keep the fixture and cap implementation unchanged.

Reconsider if configuration changes repeatedly land apart from dispatch cases or a recorded conflict shows a maintenance cost. The baseline uses the schema minimum of 2, with the measured one touch recorded separately. Score 4 triggers another look; qualifying recorded conflict cost bypasses that threshold.
