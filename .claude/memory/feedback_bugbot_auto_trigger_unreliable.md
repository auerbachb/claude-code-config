---
name: BugBot auto-trigger unreliable
description: Why we always post @cursor review on every PR push via CI and /fixpr
type: feedback
---

# BugBot auto-trigger unreliable

BugBot's GitHub "auto-trigger on push" is unreliable on later pushes even when settings suggest it should run every time. Agents used to post `@cursor review` only when no BugBot activity appeared on the new SHA after a wait; that detection frequently missed real gaps.

**Durable lesson:** BugBot's GitHub auto-trigger is unreliable on later pushes, and Cursor is billed per seat rather than per trigger. Keep the exact operational procedure in the rule/skill files; this memory exists to preserve the rationale for always favoring reliability.
