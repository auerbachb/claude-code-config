<!-- churn-hotspot: .claude/reference/cli-tool-defaults.md -->
# CLI Tool Defaults Hotspot Decision

Reference for Issue #1128 (`.claude/reference/cli-tool-defaults.md` churn hotspot). Not auto-loaded.

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-08
**Issue:** #1128
**Reporter:** `/wrap` post-merge churn report (PR #1127)

## 1. Trigger and current evidence

Issue #1128 was filed by `/wrap` churn detection after PR #1127 merged. The issue body records 3 distinct merged PRs since 2026-07-28: PR #762, PR #858, PR #1127.

At diagnosis time the file is 118 lines / approximately 666 words. It is a reference file (not auto-loaded), organized into sections: header policy paragraph, Secrets callout, Vercel, Neon, Railway, Cloudinary, and "When a CLI is unavailable" fallback.

The file was created by PR #442/#468 (merged earlier in 2026), predating the "since 2026-07-28" window in the issue report. The three flagged PRs are successive extensions of a pre-existing file.

### Per-section churn attribution

Evidence method: `gh pr diff <N> --name-only` to confirm the file appears in each PR's changed-file list, then `gh pr diff <N>` to capture the changed sections.

**CR plan's sibling-file miscount warning: confirmed negative.** The CR plan warned that the detector's three-PR count may include PRs that actually edited the cross-linked sibling file (`capability-discovery-examples.md`) rather than this file. Verified: all three PRs (#762, #858, #1127) directly edited both files simultaneously. The detector's count is accurate — there is no miscount by sibling attribution here. This is recorded as a confirmed-negative finding; it does not indicate a gap in the existence filter added by PR #1140.

| PR | Merged | Driving Issue | What changed in `cli-tool-defaults.md` |
|----|--------|--------------|----------------------------------------|
| PR #762 (`fix(#759): generalize capability discovery into an explicit CLI ladder`) | 2026-07-28 | Issue #759 | Added "These four are examples, not the allowed set" intro paragraph after the header policy line; expanded "When a CLI is unavailable" with absolute-path verification example (`ls -l /opt/homebrew/bin/{tool}`), rung-2 and rung-3 guidance, and install-annotation note |
| PR #858 (`feat(#852): add the browser as rung 4 of the capability ladder`) | 2026-08-01 | Issue #852 | Single-line correction to "When a CLI is unavailable": updated rung-4 reference to rung-5 for CLI-initiated auth flows (coordinated propagation matching the five-rung renumbering across the capability ladder cohort) |
| PR #1127 (`docs(#863): codify blended provider-CLI secrets policy`) | 2026-08-08 | Issue #863 | Railway section: added `printf '%s\n' "$VALUE" \| railway variable set {KEY} --stdin` as the preferred stdin form (Railway CLI v4.30.5+); retained legacy `--set` form with deprecation note |

### Conflict analysis

Git history is strictly linear — no merge commits and no conflict markers across any of the three PRs. Specifically:
- PR #762 added the fallback section; PR #858 made a one-line rung renumbering propagation to that same section. The edits are sequential — no concurrent modification conflict.
- PR #1127 touched only the Railway section, which no other PR in the window modified.
- No `conflict_rounds` pain on this file.

## 2. Options considered

### Option 1: KEEP (no structural change) — **Chosen**

Record a by-design KEEP decision and leave `cli-tool-defaults.md` byte-for-byte unchanged.

**Chosen.** The file's scope is "CLI command surface for installed providers." Each of the three PRs made a targeted, additive correction to a distinct part of the file (intro policy paragraph, fallback section rung renumbering, Railway preferred command form). The edits are sequentially authored and non-conflicting — the churn is the natural completion path for a file that grows when the capability ladder itself grows or when provider-CLI behavior is corrected. A structural change would relocate churn without benefit, consistent with the #1078 decision that reached the same conclusion for the cross-linked sibling file.

### Option 2: SPLIT by provider

Extract each provider section into its own file (e.g., `cli-tool-defaults/vercel.md`, `cli-tool-defaults/railway.md`).

**Rejected.** Per-provider files would multiply the files touched per new-provider PR: a new provider addition would require creating a new file plus updating the shared policy header, the Secrets callout, and the "When a CLI is unavailable" fallback — all of which are presently in one place. Provider splitting would not remove coupling to the quick-reference table in `capability-discovery-examples.md`, which references this file as a whole. The `#1078` decision reached the same conclusion when Option 3 for the sibling file proposed extracting the provider-CLI table: "Extracting it removes the catalog's value without removing the churn driver."

### Option 3: Extract shared policy/fallback sections

Move the header policy paragraph, Secrets callout, and "When a CLI is unavailable" fallback into a separate file, keeping only the per-provider command tables here.

**Rejected.** These three sections are short (together they account for less than 30% of the file) and are shared by all providers simultaneously — they are the contract framing that gives the per-provider tables their meaning. Extracting them adds files without reducing churn: the shared sections would still need updates when the capability ladder changes rungs (as PR #858 demonstrated), and the provider tables would be left without their policy context. The current file is 118 lines / ~666 words — well below any split threshold.

## 3. Preserved invariants

- **Extraction contract with `capability-discovery-examples.md`.** That file holds the "false walls → actual command" quick-reference table that delegates full command surface to this file. This file is the single authoritative CLI command surface; the quick-reference table's value depends on this file remaining stable and findable by that name.
- **Cross-link from `repo-bootstrap.md`.** The always-loaded rule `repo-bootstrap.md` references this file by name in the "Prefer installed CLI tools" note. The file's name and location must remain stable for that reference to hold.
- **For this PR:** `cli-tool-defaults.md` stays byte-for-byte unchanged.

## 4. Remediation and verification

The only changes in this PR are:
1. This decision record (`.claude/reference/cli-tool-defaults-hotspot-decision.md`).
2. One catalog bullet in `.claude/reference/README.md`.

No existing rule, script, or agent file is modified. `reference-catalog-lint.sh` must pass with exactly one registered bullet for the new decision doc and no phantom entries.

## 5. Future edits and reconsideration

Ordinary additive edits — adding a new provider section, or correcting a command for an existing provider — do not require reopening this decision.

Reconsider if:
- A future PR re-edits an *existing* section in a way that conflicts with another concurrent PR, indicating that the section has become a shared live-policy surface rather than a sequentially-authored table.
- The file duplicates another canonical doc instead of linking to it (e.g., if it begins restating the capability ladder rungs from `safety.md` in full rather than pointing to that file).
- File size roughly doubles from the current ~666 words / 118 lines, at which point per-section extraction should be reconsidered.

## 6. Related precedent

- `.claude/reference/capability-discovery-examples-hotspot-decision.md` (#1078) — KEEP decision for the cross-linked sibling file `capability-discovery-examples.md` (3 merged PRs; PRs #762, #817, #858; Issue #1078); same "additive, distinct-concern, non-conflicting" pattern; reached the same SPLIT rejection rationale (provider-level splitting relocates churn without benefit). Issue #1128 notes this is "possibly" a duplicate of #1078 — it is the same churn pattern on a different, cross-linked file, so a separate decision record is correct.
- `.claude/reference/autofile-dedup-hotspot-decision.md` — KEEP decision for `autofile-dedup.md` churn (3 merged PRs, Issue #1076); same three-PR threshold, same additive-and-non-conflicting finding.
