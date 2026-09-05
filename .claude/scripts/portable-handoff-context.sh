#!/usr/bin/env bash
# portable-handoff-context.sh — bounded, secret-free facts shared by /end and automatic checkpoint handoffs.
# catalog: utilities — Emit a bounded, secret-free JSON snapshot of the exact repository/worktree, Git/linkage state, and current-session task recovery metadata for `/end`

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CWD=""
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
NO_REMOTE=0
MAX_ITEMS="${CLAUDE_HANDOFF_MAX_ITEMS:-100}"

usage() {
  cat <<'EOF'
Usage: portable-handoff-context.sh [--cwd DIR] [--session ID] [--no-remote]

Print one JSON snapshot containing repository, worktree, Git, linkage, and
current-session background-task facts. Values that cannot be established are
reported explicitly; the script never reads arbitrary environment variables or
file contents.

Exit: 0 snapshot produced | 2 usage | 3 cwd unavailable | 4 dependency/internal
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cwd|--session)
      (( $# >= 2 )) || { echo "portable-handoff-context.sh: $1 requires a value" >&2; exit 2; }
      if [[ "$1" == --cwd ]]; then CWD="$2"; else SESSION_ID="$2"; fi
      shift ;;
    --no-remote) NO_REMOTE=1 ;;
    *) echo "portable-handoff-context.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "portable-handoff-context.sh: jq is required" >&2; exit 4; }
[[ "$MAX_ITEMS" =~ ^[1-9][0-9]*$ ]] || MAX_ITEMS=100
MAX_ITEMS=$((10#$MAX_ITEMS))
(( MAX_ITEMS <= 500 )) || MAX_ITEMS=500
[[ -n "$SESSION_ID" ]] || SESSION_ID=default

if [[ -n "$CWD" ]]; then
  [[ -d "$CWD" ]] || { echo "portable-handoff-context.sh: cwd is unavailable: $CWD" >&2; exit 3; }
  WORKING_DIR=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 3
else
  WORKING_DIR=$(pwd -P 2>/dev/null || pwd)
fi

unknown="unknown"
collected_at=$(date -u +%FT%TZ 2>/dev/null || printf '%s' "$unknown")
repo_identity="$unknown"
repo_root="$unknown"
repo_lookup="not a git checkout"
checkout_path="$WORKING_DIR"
checkout_condition="not a git checkout"
branch="$unknown"
base_branch="$unknown"
head_sha="$unknown"
upstream="$unknown"
unpushed="$unknown"
pr_number=""
pr_url=""
issue_number=""
issue_url=""
linkage_status="not looked up outside a git checkout"
tasks_status="not looked up because repository identity is unknown"
tasks_json='[]'
tasks_total=0
tracked_json='[]'
untracked_json='[]'
tracked_total=0
untracked_total=0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/portable-handoff-context.XXXXXX") || exit 4
trap 'rm -rf "$TMP_DIR"' EXIT

# One policy for every externally supplied string that can reach the persistent
# handoff: Git paths and task metadata must never drift onto different secret
# rules. Keep provider-specific formats ahead of the generic labeled forms.
REDACT_JQ='
  def redact:
    gsub("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"; "[REDACTED]")
    | gsub("(?i)bearer[[:space:]]+[A-Za-z0-9._~+/=-]{8,}"; "[REDACTED]")
    | gsub("(AKIA|ASIA)[A-Z0-9]{16}"; "[REDACTED]")
    | gsub("AIza[0-9A-Za-z_-]{35}"; "[REDACTED]")
    | gsub("xox[baprs]-[0-9A-Za-z-]{10,}"; "[REDACTED]")
    | gsub("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"; "[REDACTED]")
    | gsub("gh[pousr]_[A-Za-z0-9]{10,}"; "[REDACTED]")
    | gsub("sk-[A-Za-z0-9_-]{10,}"; "[REDACTED]")
    | gsub("(?i)(https?://)[^/@[:space:]]+:[^/@[:space:]]+@"; "https://[REDACTED]@")
    | gsub("(?i)(authorization|api[_-]?key|access[_-]?token|token|password|secret)[[:space:]]*[:=][[:space:]]*(bearer[[:space:]]+)?[^[:space:]]+"; "[REDACTED]")
    | gsub("(?i)(^|/)(api[_-]?key|access[_-]?token|token|password|secret)/[^/[:space:]]+"; "/[REDACTED]");
'

collect_nul_stream() {
  local list_file="$1" count_file="$2" item fifo producer rc total
  shift 2
  : >"$list_file"
  fifo="$list_file.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" || return 1
  "$@" >"$fifo" 2>/dev/null &
  producer=$!
  total=0
  while IFS= read -r -d '' item; do
    total=$((total + 1))
    if (( total <= MAX_ITEMS )); then
      printf '%s\0' "$item" >>"$list_file"
    fi
  done <"$fifo"
  wait "$producer"
  rc=$?
  rm -f "$fifo"
  if (( rc != 0 )); then
    rm -f "$list_file" "$count_file"
    return "$rc"
  fi
  printf '%s\n' "$total" >"$count_file"
}

if git -C "$WORKING_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  checkout_path=$(git -C "$WORKING_DIR" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$WORKING_DIR")
  checkout_path=$(cd "$checkout_path" 2>/dev/null && pwd -P || printf '%s' "$checkout_path")
  repo_lookup="resolved"

  if [[ -x "$SCRIPT_DIR/repo-root.sh" ]] && root=$("$SCRIPT_DIR/repo-root.sh" "$checkout_path" 2>/dev/null); then
    repo_root="$root"
  else
    repo_root="$unknown"
    repo_lookup="main repository root could not be resolved"
  fi
  if [[ "$repo_root" != "$unknown" && "$checkout_path" == "$repo_root" ]]; then
    checkout_condition="main worktree"
  elif [[ "$repo_root" != "$unknown" ]]; then
    checkout_condition="linked worktree"
  else
    checkout_condition="git checkout; worktree condition unknown"
  fi

  branch=$(git -C "$checkout_path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached HEAD')
  head_sha=$(git -C "$checkout_path" rev-parse --verify HEAD 2>/dev/null || printf '%s' "$unknown")
  upstream=$(git -C "$checkout_path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || printf '%s' "$unknown")
  if [[ "$upstream" != "$unknown" ]]; then
    unpushed=$(git -C "$checkout_path" rev-list --count "${upstream}..HEAD" 2>/dev/null || printf '%s' "$unknown")
  fi

  if [[ "$head_sha" != "$unknown" ]]; then
    collect_nul_stream "$TMP_DIR/tracked" "$TMP_DIR/tracked-count" \
      git -C "$checkout_path" diff --name-only -z HEAD -- || {
        echo "portable-handoff-context.sh: tracked changes could not be read" >&2
        exit 4
      }
  else
    collect_nul_stream "$TMP_DIR/tracked" "$TMP_DIR/tracked-count" \
      git -C "$checkout_path" diff --cached --name-only -z -- || {
        echo "portable-handoff-context.sh: staged changes could not be read" >&2
        exit 4
      }
  fi
  collect_nul_stream "$TMP_DIR/untracked" "$TMP_DIR/untracked-count" \
    git -C "$checkout_path" ls-files --others --exclude-standard -z -- || {
      echo "portable-handoff-context.sh: untracked changes could not be read" >&2
      exit 4
    }
  tracked_json=$(jq -Rs "$REDACT_JQ"$'\n''split("\u0000") | map(select(length > 0) | redact)' \
    <"$TMP_DIR/tracked") || exit 4
  untracked_json=$(jq -Rs "$REDACT_JQ"$'\n''split("\u0000") | map(select(length > 0) | redact)' \
    <"$TMP_DIR/untracked") || exit 4
  tracked_total=$(<"$TMP_DIR/tracked-count")
  untracked_total=$(<"$TMP_DIR/untracked-count")

  remote=$(git -C "$checkout_path" remote get-url origin 2>/dev/null || true)
  case "$remote" in
    *github.com:*) slug="${remote##*github.com:}" ;;
    *github.com/*) slug="${remote##*github.com/}" ;;
    *) slug="" ;;
  esac
  slug="${slug%.git}"
  slug="${slug%%\?*}"
  slug="${slug%%#*}"
  if [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    repo_identity=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  fi

  if (( NO_REMOTE )); then
    linkage_status="remote lookup skipped"
  elif command -v gh >/dev/null 2>&1 && [[ "$branch" != "detached HEAD" ]]; then
    pr_json=$(cd "$checkout_path" && GH_HTTP_TIMEOUT="${GH_HTTP_TIMEOUT:-10}" gh pr view "$branch" \
      --json number,url,baseRefName 2>/dev/null) || pr_json=""
    if [[ -n "$pr_json" ]] && jq -e 'type == "object" and (.number | type == "number")' >/dev/null 2>&1 <<<"$pr_json"; then
      pr_number=$(jq -r '.number' <<<"$pr_json")
      pr_url=$(jq -r '.url // empty' <<<"$pr_json")
      pr_base=$(jq -r '.baseRefName // empty' <<<"$pr_json")
      [[ -n "$pr_base" ]] && base_branch="$pr_base"
      linkage_status="pull request resolved from current branch"
      if [[ -x "$SCRIPT_DIR/pr-issue-ref.sh" ]]; then
        # --first (issue #1492): default mode is set-valued, and issue_number is
        # interpolated into a single issue URL below — a two-line value would
        # build a URL with a newline in it.
        issue_number=$(cd "$checkout_path" && "$SCRIPT_DIR/pr-issue-ref.sh" --first "$pr_number" 2>/dev/null) || issue_rc=$?
        issue_rc="${issue_rc:-0}"
        if [[ -n "$issue_number" && "$repo_identity" != "$unknown" ]]; then
          issue_url="https://github.com/${repo_identity}/issues/${issue_number}"
        elif (( issue_rc > 1 )); then
          linkage_status="pull request resolved; linked issue lookup failed"
        fi
      fi
    else
      linkage_status="no pull request resolved from current branch"
    fi
  else
    linkage_status="remote lookup unavailable"
  fi

  if [[ -z "$issue_number" && "$branch" =~ (^|[^[:alnum:]])issue-([1-9][0-9]*)(-|$) ]]; then
    issue_number="${BASH_REMATCH[2]}"
    [[ "$repo_identity" != "$unknown" ]] && issue_url="https://github.com/${repo_identity}/issues/${issue_number}"
    [[ "$linkage_status" == "no pull request resolved from current branch" ]] && linkage_status="issue resolved from exact branch token"
  fi

  if [[ -x "$SCRIPT_DIR/background-task-registry.sh" ]]; then
    registry_repo="$repo_identity"
    if [[ "$registry_repo" == "$unknown" && "${CLAUDE_SESSION_REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
      registry_repo=$(printf '%s' "$CLAUDE_SESSION_REPO" | tr '[:upper:]' '[:lower:]')
    fi
    [[ "$registry_repo" == "$unknown" ]] && registry_repo="_unknown"
    raw_tasks=$(cd "$checkout_path" && "$SCRIPT_DIR/background-task-registry.sh" \
      --repo "$registry_repo" --list --session "$SESSION_ID" 2>/dev/null) || raw_tasks=""
    if [[ -n "$raw_tasks" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw_tasks"; then
      tasks_total=$(jq 'length' <<<"$raw_tasks") || exit 4
      tasks_json=$(jq --argjson max "$MAX_ITEMS" "$REDACT_JQ"$'\n''
        [.[] | {task_id, name, type, status,
                 work_item:(.work_item // null), output_file,
                 checkpoint_path:(.checkpoint_path // null), recovery_path,
                 started_at, updated_at, stale}
               | with_entries(.value |= if type == "string" then redact else . end)]
        | .[:$max]
      ' <<<"$raw_tasks") || exit 4
      tasks_status="resolved"
    else
      tasks_status="background-task registry could not be read"
    fi
  fi
fi

jq -cn \
  --arg collected_at "$collected_at" --arg session "$SESSION_ID" \
  --arg identity "$repo_identity" --arg root "$repo_root" --arg repo_status "$repo_lookup" \
  --arg path "$checkout_path" --arg condition "$checkout_condition" \
  --arg branch "$branch" --arg base "$base_branch" --arg head "$head_sha" \
  --arg upstream "$upstream" --arg unpushed "$unpushed" \
  --argjson tracked "$tracked_json" --argjson untracked "$untracked_json" \
  --argjson tracked_total "$tracked_total" --argjson untracked_total "$untracked_total" \
  --arg pr_number "$pr_number" --arg pr_url "$pr_url" \
  --arg issue_number "$issue_number" --arg issue_url "$issue_url" \
  --arg linkage_status "$linkage_status" --arg tasks_status "$tasks_status" \
  --argjson tasks "$tasks_json" --argjson tasks_total "$tasks_total" --argjson max "$MAX_ITEMS" '
    def maybe_number($v): if $v == "" then null else ($v | tonumber? // $v) end;
    {schema_version:1, collected_at:$collected_at, session_id:$session,
     repository:{identity:$identity, root:$root, lookup_status:$repo_status},
     working_copy:{path:$path, condition:$condition, branch:$branch,
       base_branch:$base, head:$head, upstream:$upstream,
       unpushed_commits:(maybe_number($unpushed)),
       tracked_changes:$tracked, tracked_change_count:$tracked_total,
       untracked_changes:$untracked, untracked_change_count:$untracked_total,
       lists_truncated:(($tracked_total > $max) or ($untracked_total > $max))},
     linkage:{lookup_status:$linkage_status,
       pull_request:{number:(maybe_number($pr_number)), url:(if $pr_url == "" then null else $pr_url end)},
       issue:{number:(maybe_number($issue_number)), url:(if $issue_url == "" then null else $issue_url end)}},
     background_tasks:{lookup_status:$tasks_status, items:$tasks,
       total:$tasks_total, truncated:($tasks_total > $max)}}'
