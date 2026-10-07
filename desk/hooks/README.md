# desk/hooks/

Hook implementations for the human queue live here.

| File | What it is |
|------|------------|
| `capture.sh` | The capture hook (issue #1755): a `PreToolUse` hook on `AskUserQuestion` that sends a thread's questions to the store instead of rendering them in the thread, while a live desk exists. A bash launcher that resolves its own location and runs `capture.py` |
| `capture.py` | The capture hook's logic (Python 3.9: the input is nested JSON, and every CLI call needs a hard timeout that kills its process group) |

Claude Code registers hooks from `.claude/hooks/`, so each hook here gets an
entry there that is a symlink into this folder
(`.claude/hooks/human-queue-capture.sh` → `../../desk/hooks/capture.sh`) and a
`global-settings.json` entry that `register-hooks.py` installs at session
start. A hook finds the CLI relative to its own resolved location
(`../bin/human-queue.sh`; tests override it with `HUMAN_QUEUE_CLI`) and fails
open on any failure, the CLI's exit 7 included.

The contract (the live-desk gate, the deny reason, what a Decision carries,
where the URL comes from, and every fail-open path) is in `../README.md`,
"Capture hook".
