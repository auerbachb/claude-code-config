#!/usr/bin/env bash
# Shared repo builder, handoff writer, and gh stub factory for the
# polling-state-gate.sh test suites. This file intentionally does not end in
# .test.sh, so run-hook-tests.sh will not execute it directly.
#
# Source this file from a *.test.sh suite; do NOT execute it directly:
#   TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/polling-state-gate-fixtures.sh
#   source "$TEST_DIR/lib/polling-state-gate-fixtures.sh"
#
# WHAT THIS PROVIDES
#   mk_repo <dir> <origin-url>
#     Creates a throwaway git repo with one commit, needed for git worktree add.
#
#   write_handoff <owner_repo_or_empty> <pr_number> <head_sha>
#     Writes a minimal handoff JSON via handoff-state.sh. When owner_repo is
#     non-empty the handoff lands at the scoped path
#     ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json (issue #655).
#     When empty it uses the legacy flat path.
#
#   write_polling_gh_stub <bin_dir>
#     Writes an env-var-driven gh stub. Callers set these env vars when
#     invoking the gate script (inline VAR=value before the command):
#       STUB_OWNER_REPO   — `gh repo view` response and default PR JSON slug
#                           (default: org/c)
#       STUB_PR_JSON      — full JSON for `gh pr view` (optional; when absent
#                           the stub builds it from STUB_HEAD_SHA /
#                           STUB_OWNER_REPO / STUB_PR_NUMBER)
#       STUB_HEAD_SHA     — headRefOid in the default PR JSON (default: ccc3333)
#       STUB_PR_NUMBER    — PR number in the default PR JSON (default: 84)
#       STUB_PR_AUTHOR    — login for the PR author authorship check
#                           (default: testuser); `gh api user` always returns
#                           "testuser" as the viewer login
#
# WHAT IS DELIBERATELY EXCLUDED
#   check_eq / check_contains — kept per-file per the repo-wide convention.
#   TMP / TMP_HOME / HOME setup — each suite manages its own temp dirs and
#   cleanup traps to preserve independent isolation guarantees.

# Guard against direct execution — this file only defines functions and does
# nothing else, so running it would silently succeed and provide nothing.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  echo "polling-state-gate-fixtures.sh: source this file, do not execute it directly" >&2
  exit 2
fi

_PSG_FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PSG_REPO_ROOT="$(git -C "$_PSG_FIXTURE_DIR" rev-parse --show-toplevel)"
_PSG_HANDOFF_HELPER="$_PSG_REPO_ROOT/.claude/scripts/handoff-state.sh"

# mk_repo <dir> <origin-url>
# Creates a throwaway git repo with one commit (needed for git worktree add).
# Uses -c flags for user config so no global git config is modified.
mk_repo() {
  local dir="$1" origin="$2"
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" remote add origin "$origin"
  : > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.email=test@example.com -c user.name=Test commit --quiet -m init
}

# write_handoff <owner_repo_or_empty> <pr_number> <head_sha>
# Writes a minimal handoff JSON via handoff-state.sh. A non-empty owner_repo
# routes to the scoped path ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
# (issue #655); an empty owner_repo uses the legacy flat path.
# Callers must have set HOME to a temp directory and created $HOME/.claude/handoffs.
write_handoff() {
  local owner_repo="${1:-}" pr="${2}" sha="${3}"
  local json_body
  json_body="$(jq -n --argjson pr "$pr" --arg sha "$sha" \
    '{schema_version:"1.0", pr_number:$pr, head_sha:$sha, reviewer:"cr",
      phase_completed:"B", created_at:"2026-07-21T00:00:00Z",
      findings_fixed:[], threads_replied:[], threads_resolved:[],
      files_changed:[], push_timestamp:"2026-07-21T00:00:00Z"}')"
  if [[ -n "$owner_repo" ]]; then
    "$_PSG_HANDOFF_HELPER" --owner-repo "$owner_repo" --create "$pr" "$json_body"
  else
    # An empty owner_repo means this fixture wants the LEGACY FLAT handoff —
    # the pre-migration state several gate tests set up deliberately. Say so
    # with --legacy-flat (issue #1366): omitting the scope now derives one from
    # the cwd, which under `bash .claude/scripts/tests/...` is this very repo,
    # so the fixture would silently write a scoped file and the gate would then
    # report the flat handoff missing.
    "$_PSG_HANDOFF_HELPER" --legacy-flat --create "$pr" "$json_body"
  fi
}

# write_polling_gh_stub <bin_dir>
# Writes a gh stub script that reads from env vars at runtime (set inline on
# each gate invocation). The stub covers all surface areas exercised by
# polling-state-gate.sh, pr-authorship.sh, and the pr-state.sh calls made
# during --ensure-session's poll-watermarks.sh --init step.
write_polling_gh_stub() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
_owner_repo="${STUB_OWNER_REPO:-org/c}"
_head_sha="${STUB_HEAD_SHA:-ccc3333}"
_pr_num="${STUB_PR_NUMBER:-84}"
_pr_author="${STUB_PR_AUTHOR:-testuser}"

# Real `gh` post-processes its own JSON with --jq before printing, independent
# of --json. Mirror that here for the `pr` subcommand (the only caller that
# uses it, e.g. `gh pr view N --json headRefOid --jq '.headRefOid'`) so a
# caller expecting the extracted field doesn't get the raw object instead.
_gh_jq_filter=""
for ((_i=1; _i<=$#; _i++)); do
  if [[ "${!_i}" == "--jq" ]]; then
    _next=$((_i+1))
    _gh_jq_filter="${!_next:-}"
    break
  fi
done
_emit() {
  if [[ -n "$_gh_jq_filter" ]]; then
    jq -r "$_gh_jq_filter"
  else
    cat
  fi
}

case "${1:-}" in
  pr)
    if [[ -n "${STUB_PR_JSON:-}" ]]; then
      printf '%s\n' "$STUB_PR_JSON" | _emit
    else
      printf '{"headRefOid":"%s","state":"OPEN","number":%s,"headRefName":"feature","url":"https://github.com/%s/pull/%s","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}\n' \
        "$_head_sha" "$_pr_num" "$_owner_repo" "$_pr_num" | _emit
    fi ;;
  repo) printf '%s\n' "$_owner_repo" ;;
  api)
    shift
    [[ "${1:-}" == "--paginate" ]] && shift
    case "${1:-}" in
      user) echo 'testuser' ;;
      graphql)
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
        ;;
      repos/*/pulls/*)
        if [[ "$*" == *"/reviews"* || "$*" == *"/comments"* ]]; then
          echo '[]'
        else
          printf '{"user":{"login":"%s","type":"User"}}\n' "$_pr_author"
        fi ;;
      repos/*/issues/*/comments*) echo '[]' ;;
      repos/*/commits/*/check-runs*) echo '{"check_runs":[]}' ;;
      repos/*/commits/*/statuses*) echo '[]' ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$bin_dir/gh"
}
