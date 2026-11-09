# Quota setup runtime hotspot decision

Issue #1907. The untruncated default-branch detector after PR #2068 counted five changes to `ai-quotas-setup.sh`, with score 5 and no recorded conflicts.

KEEP the setup command together. Its actions share registry validation, provider and label resolution, and the profile paths that protect account identity. The reader and browser workflow already live separately. Extracting the config-sharing commands would be the strongest split: they operate on resolved files and could be tested independently, but would need a stable path and refusal contract from the setup command. The current evidence does not show merge conflicts or an independent deployment that justify that split.

| Counted PR | Setup change |
|---|---|
| #1852 | Added launchers and configuration sharing. |
| #1891 | Detected and repaired cross-wired profile layouts. |
| #1896 | Configured ordered source fallback and browser read settings. |
| #1905 | Added session account and project history wiring. |
| #2004 | Verified fresh-profile recovery and clarified the login path. |

The first three were also in the original issue report. Keep the measured score/count 5 baseline and the existing 2× growth threshold. Reconsider a split if several changes conflict at the sharing boundary, or if sharing needs a caller independent of the registry.

## Sharing guard

`share-config` copies a profile's `.claude.json` before installing a merged file. A private test copied the backup and then atomically replaced the live file with newer fields; the old command overwrote those fields and reported success. Another control replaced the target with a directory and the old command installed its temporary file inside it.

The sharing action stages the merge and verifies the backup inside a private directory, then publishes it only if the intended backup name is still free. It compares the backup to the regular live file just before installing, including a check that the live mode still matches the original. On a mismatch it leaves the live path alone, keeps any published backup, and discards the staged merge. Ordinary sharing preserves the live file’s unrelated fields and mode. A published backup has no group or other mode bits, so it cannot retain a wider octal mode after a permission change. The profile must be idle: an unrelated writer can still race the final comparison and rename.
