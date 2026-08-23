# Tier Inference — issue-maker single-issue subset

Consumed by Step 9b to produce the tier statement and model step-up warning in
the inline-run offer, and the `**Model:**` and `**Effort:**` lines for the
on-request chip/fallback block. This is a **trimmed single-issue** version of `/prompt`'s
Heavy/Standard/Light mapping (`prompt/SKILL.md` Steps 4–5): no batch
aggregation, no dependency counting, no Fable step-up.

## Signals to compute from the body drafted in Step 5

| Signal | How to compute |
|--------|----------------|
| `file_count` | Paths under `## Related Files` plus backticked paths in the body containing `/` and a file extension |
| `ac_count` | Count of `- [ ]` lines under `## Acceptance Criteria` |
| `touches_rules` | Any counted path matches `.claude/rules/` |
| `touches_claude_md` | Any counted path matches `CLAUDE.md` |
| `touches_skill` | Any counted path matches `.claude/skills/` |
| `has_orchestration_keywords` | Body mentions "subagent", "Phase A/B/C", "multi-phase", "orchestration", "monitor mode", "handoff" |
| `scope_keywords` | Title/body mentions "typo", "rename", "comment", "config", "doc update", "README", "formatting" |

## Classification table (evaluate top to bottom, stop at first match)

| Tier | Trigger (any is sufficient) | Model / effort |
|------|-----------------------------|----------------|
| **Heavy** | `touches_rules`, `touches_claude_md`, `has_orchestration_keywords`, or `file_count > 5` | Opus, Extra (step up to Max for correctness-critical work — see `prompt/SKILL.md` Step 5) |
| **Standard** | not Heavy, and (`file_count` 2–5, `ac_count > 3`, or `touches_skill`) | Opus, High |
| **Light** | not Heavy/Standard, **and** a positive Light signal: any `scope_keywords` present, or `file_count ≤ 1` with a clear single-file scope | Sonnet, Low |

**Evaluate in table order and stop at the first match.** A `touches_rules` or
orchestration trigger wins over a `scope_keywords` hit on the same issue.

**Light requires a positive signal**, not merely the absence of the other two.
Were it the plain complement of Heavy/Standard, a thin unclassifiable body would
silently land on the cheapest tier instead of the safe Standard default.

**Default to Standard** when signals are too sparse to classify confidently
(thin bodies, terse rapid-fire captures) — the safer choice absent a strong
signal either way.

Model values are bare family names; effort values are picker labels — never a
version number, never a bare API token (`chip-launching.md` "Model and effort
lines").
