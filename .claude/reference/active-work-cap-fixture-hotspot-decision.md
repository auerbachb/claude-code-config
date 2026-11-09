# Active-work cap fixture hotspot decision

Issue #1296. **Keep the active-work cap fixture together.** It uses one isolated repo and fake GitHub reader to check the effective cap, PRs, offers, pre-PR pipelines, and read failures. The offer cases also check that the registry and legacy log do not double-count. The cap and ceiling checks need the same configuration and count contract as the dispatch cases.

The original report counted #1224, #1250, #1252, and #1267, including fixture creation in #1224. The current window since October 26, 2026, contains one change: #1924 raised the supported cap bound and updated its checks. It falls below the detector's two-PR floor, with no recorded conflict cost.

A separate configuration test could help if those cases gain their own setup or start changing independently. The recent bound change has neither problem. Splitting today would duplicate the fake source setup or add a helper boundary without reducing a demonstrated cost. Keep the fixture and cap implementation unchanged.

Reconsider if configuration and dispatch cases start changing independently or a recorded conflict shows a maintenance cost. The baseline uses the schema minimum of 2, with the measured one touch recorded separately. Score 4 triggers another look; qualifying recorded conflict cost bypasses that threshold.
