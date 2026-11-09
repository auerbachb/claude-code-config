# Skill portability lint hotspot decision

Issue #1331. **Keep the portability lint together.** Published-surface discovery, shell-candidate checks, and verbatim prompt checks use the same list of installed skills and fail when a required surface is missing. The existing shared discovery helper and local parser functions already separate the recurring mechanics.

The original window counted #1196, #1256, #1313, #1320, and #1327. It included creation in #1196 and broad changes that the current detector excludes. In the current window since October 26, 2026, #1879 and #2079 touched the lint as part of 26- and 62-file changes. Both exceed the detector's 20-file sweep threshold, so the measured count and score are zero. The module discovery and unset-HOME checks they added are still covered by the existing fixture.

A separate parser could help if another lint needed the same candidate recognition. No such recurring split is established here. Keeping the checks together preserves one guarded-surface decision and one missing-surface failure path. The lint, its shared helpers, and its existing fixture stay unchanged.

Reconsider if distinct consumers need the parser or the lint records recurring conflict cost. The baseline entry uses the schema minimum of 2 and records the measured zero separately. Score 4 brings the file back for a decision; a qualifying recorded conflict bypasses that threshold.
