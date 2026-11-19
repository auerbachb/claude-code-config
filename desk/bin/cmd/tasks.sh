# shellcheck shell=bash
# summary: the operator's open human tasks across repos, read from owner-task.sh (never stored here)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR. Never connects to the store.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/owner-tasks.sh
. "$HQ_BIN_DIR/lib/owner-tasks.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh tasks — the operator's open human tasks across repos
(issue #2542).

USAGE
  human-queue.sh tasks [--json]

WHAT IT READS
  The tasks only a person can do (fill in a .env, sign in, accept an
  agreement), kept on GitHub one list per repo by owner-task.sh (issue
  #2538). This runs `owner-task.sh list --all-repos --json` and prints the
  open ones; it stores nothing and never connects to the store, so the
  database URL is not needed. Marking a task done happens on the list
  itself (`owner-task.sh done ID --proof TEXT`).

  owner-task.sh is the first executable of
    ~/.claude/skills-worktree/.claude/scripts/owner-task.sh
    ~/.claude/scripts/owner-task.sh
    .claude/scripts/owner-task.sh   (relative to the current directory)

OUTPUT
  Text: a header line, then each repo and its tasks, oldest first:
    2 open human tasks in 1 repo
    owner/name
      ht-1a2b3c4d  Fill in .env for staging
                   why a person: needs your API key · from: PR #12 · since 2026-11-18
  or `No open human tasks.`
  --json: {"readable": true, "reason": null, "count": N, "repos": N,
           "tasks": [{id, repo, what, why, source, created_at, state,
                      done_at, proof}, ...]}
  Task text is printed on one line each: control characters become spaces.

  When the list cannot be read (owner-task.sh missing, a non-zero exit —
  offline, gh unavailable or signed out — or output that is not a task
  list), it says so: one line on stderr naming the reason, and with --json
  {"readable": false, "reason": "...", "count": null, "repos": null,
   "tasks": []} on stdout. That is never "no tasks".

EXIT CODES
  0  ok (no open tasks included)
  1  the task list could not be read
  4  a stray argument or unknown option
EOF
}

# hq__tasks_text — the open-task array (stdin) as the text view.
hq__tasks_text() {
  jq -r '
    def one: tostring | gsub("[\u0000-\u001f\u007f]"; " ");
    (map(.repo) | unique | length) as $repos
    | if length == 0 then "No open human tasks."
      else
        "\(length) open human task\(if length == 1 then "" else "s" end) in \($repos) repo\(if $repos == 1 then "" else "s" end)",
        (group_by(.repo)[]
         | (.[0].repo | one),
           (.[] | "  \(.id | one)  \(.what | one)",
                  ("               " + ([ (if (.why // "") != "" then "why a person: \(.why | one)" else empty end),
                                         (if (.source // "") != "" then "from: \(.source | one)" else empty end),
                                         (if (.created_at // "") != "" then "since \(.created_at | one | .[0:10])" else empty end) ]
                                       | join(" · "))
                   | select(test("[^ ]")))))
      end'
}

cmd_run() {
  local json=0 tasks reason
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      -*) hq_die_validation "tasks: unknown $(hq_flag_name "$1") (run human-queue.sh tasks --help)" ;;
      *) hq_die_validation "tasks: takes no arguments besides --json (run human-queue.sh tasks --help)" ;;
    esac
    shift
  done
  if ! hq_owner_tasks_read tasks reason; then
    if [ "$json" -eq 1 ] && command -v jq >/dev/null 2>&1; then
      jq -cn --arg r "$reason" '{readable: false, reason: $r, count: null, repos: null, tasks: []}'
    elif [ "$json" -eq 1 ]; then
      # No jq (the only reason the read fails before running the script): the
      # same object, its reason escaped by hand.
      local r="${reason//\\/\\\\}"
      r="${r//\"/\\\"}"
      printf '{"readable":false,"reason":"%s","count":null,"repos":null,"tasks":[]}\n' "$r"
    fi
    hq_die_error "tasks: the task list could not be read ($reason)"
  fi
  if [ "$json" -eq 1 ]; then
    printf '%s' "$tasks" | jq -c '{readable: true, reason: null, count: length,
                                   repos: (map(.repo) | unique | length), tasks: .}'
  else
    printf '%s' "$tasks" | hq__tasks_text
  fi
}
