<!-- pm-routing:begin -->
Consider the existing handoff prompt only at its context-length gate.
<!-- pm-routing:end -->

When the conversation is getting long (many back-and-forth cycles, multiple batches of work completed), proactively suggest:

> "This PM session has been running for a while. To preserve context for a fresh thread, run `/pm-handoff` — it will capture the current state, memory, and in-flight work into a prompt you can paste into a new PM session."

