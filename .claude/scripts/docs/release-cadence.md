# Release Cadence

Scripts that decide when a merge is worth a TestFlight build and follow the build to a terminal state. TestFlight only — the App Store path is never triggered. Mechanism: `.claude/reference/release-cadence.md`.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
| [release-policy.sh](../release-policy.sh) | Resolve a repo's release policy (default off) and derive the `auto` build interval from its own run history |
| [release-decide.sh](../release-decide.sh) | Decide whether a merge warrants a build, and optionally pull the trigger that repo already uses |
| [release-sweep.sh](../release-sweep.sh) | Cut pending builds once their window opens and surface failed, skipped, or never-started releases |

---

[← back to the index](../README.md)
