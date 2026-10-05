# desk/hooks/

Hook implementations for the human queue live here. The first, the capture
hook that sends a thread's questions to the store instead of rendering them in
the thread, arrives with issue #1755.

Claude Code registers hooks from `.claude/hooks/`, so each hook here gets an
entry there that is a symlink into this folder. A hook finds the CLI relative
to its own resolved location (`../bin/human-queue.sh`) and fails open on the
CLI's exit 7 (see `../README.md`).
