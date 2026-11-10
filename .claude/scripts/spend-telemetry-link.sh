#!/usr/bin/env bash
# catalog: token-measurement — Record explicit session/task to issue/PR correlation and bounded post-merge evidence
# Explicit, best-effort bridge from a known Claude session/task to an issue/PR.
# No hook calls this; optional GitHub lookup happens only at the workflow boundary.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: spend-telemetry-link.sh [--session ID] [--repo OWNER/REPO] --issue N
       [--pr N] [--task ID] [--agent ID] [--source NAME]
       [--gate-passed --gate-head-sha SHA --gate-result JSON]

Append explicit metadata correlation to ~/.claude/spend-telemetry.log. A real
session ID is required for issue-only links; PR-only evidence may omit it.
With --pr, one bounded `gh pr view` validates issue linkage and records merged,
review, current-check, and commit-count metadata. --gate-passed requires the
exact PR head SHA and structured JSON result observed by the passing merge gate; the post-merge PR head
must match it. The squash merge SHA is stored separately and never compared as
the reviewed PR head.
Telemetry failures are non-blocking. No transcript or task text is recorded.
EOF
}

SESSION_ID="" REPO="" ISSUE="" PR="" TASK_ID="" AGENT_ID="" SOURCE="explicit_workflow" GATE_PASSED=0 GATE_HEAD_SHA="" GATE_RESULT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session|--repo|--issue|--pr|--task|--agent|--source|--gate-head-sha|--gate-result)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "ERROR: $1 requires a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --session) SESSION_ID="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --task) TASK_ID="${2:-}"; shift 2 ;;
    --agent) AGENT_ID="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --gate-passed) GATE_PASSED=1; shift ;;
    --gate-result) GATE_RESULT="${2:-}"; shift 2 ;;
    --gate-head-sha) GATE_HEAD_SHA="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" 2>/dev/null && pwd)/lib/spend-telemetry-recorder.sh"
[[ -r "$RECORDER" ]] || exit 0
. "$RECORDER" 2>/dev/null || exit 0


SESSION_ID="$(_spend_resolve_session "$SESSION_ID")"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO" ]]; then
  REPO="${GH_REPO:-}"
  if [[ -z "$REPO" && -n "$REPO_ROOT" ]]; then
    REPO="$(_spend_repo_slug_from_cwd "$REPO_ROOT")"
  fi
fi
[[ -n "$ISSUE" ]] || { echo "ERROR: --issue is required" >&2; exit 2; }
[[ "$SESSION_ID" != unknown || -n "$PR" ]] || exit 0
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "ERROR: --repo or resolved GH_REPO/origin must be OWNER/REPO" >&2; exit 2; }
[[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --issue must be a positive number" >&2; exit 2; }
[[ -z "$PR" || "$PR" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --pr must be a positive number" >&2; exit 2; }
for TELEMETRY_ID in "$TASK_ID" "$AGENT_ID" "$SOURCE"; do
  [[ -z "$TELEMETRY_ID" || ( ${#TELEMETRY_ID} -le 512 && "$TELEMETRY_ID" =~ ^[A-Za-z0-9_.:/@+-]+$ ) ]] || { echo "ERROR: task/agent/source must be metadata identifiers" >&2; exit 2; }
done
[[ "$GATE_PASSED" != 1 || -n "$PR" ]] || { echo "ERROR: --gate-passed requires --pr" >&2; exit 2; }
[[ "$GATE_PASSED" != 1 || "$GATE_HEAD_SHA" =~ ^[a-fA-F0-9]{40}$ ]] || { echo "ERROR: --gate-passed requires a full --gate-head-sha observed by merge-gate.sh" >&2; exit 2; }
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"


EVIDENCE_JSON="$(python3 - "$REPO" "$ISSUE" "$PR" "$SOURCE" "$GATE_HEAD_SHA" "$GATE_RESULT" <<'PY' 2>/dev/null || printf '{}'
import json, sys
repo, issue, pr, source, gate_head_sha, _gate_result = sys.argv[1:]
print(json.dumps({"repo": repo, "issue": int(issue), "pr": int(pr) if pr else None,
                  "capture_source": source, "pr_state": "UNKNOWN",
                  "gate_head_sha": gate_head_sha or None}, separators=(",", ":")))
PY
)"
if [[ -n "$PR" ]]; then
  PR_JSON=""
  if command -v gh >/dev/null 2>&1; then
  PR_JSON="$(python3 - "$PR" "$REPO" <<'PYGH' 2>/dev/null || true
import subprocess,sys
# Project at the CLI: no commit messages, review bodies, or issue text in argv/logs.
projection='{number,url,state,mergedAt,closingIssuesReferences,reviewDecision,statusCheckRollup,headRefOid,mergeCommit,commit_count:(.commits|length)}'
try:
    result=subprocess.run(["gh","pr","view",sys.argv[1],"--repo",sys.argv[2],"--json","number,url,state,mergedAt,closingIssuesReferences,reviewDecision,statusCheckRollup,commits,headRefOid,mergeCommit","--jq",projection],capture_output=True,timeout=10)
    if result.returncode==0 and len(result.stdout)<=65536: sys.stdout.buffer.write(result.stdout)
except (OSError,subprocess.TimeoutExpired): pass
PYGH
)"
  fi
  EVIDENCE_JSON="$(python3 - "$PR_JSON" "$REPO" "$ISSUE" "$PR" "$GATE_PASSED" "$SOURCE" "$GATE_HEAD_SHA" "$GATE_RESULT" <<'PY' 2>/dev/null || printf '{}'
import json, sys
raw, repo, issue, pr, gate_passed, capture_source, gate_head_sha, gate_result = sys.argv[1:]
evidence = {
    "source": "gh.pr.view" if raw else "gh.pr.view:unavailable",
    "capture_source": capture_source,
    "repo": repo,
    "issue": int(issue),
    "pr": int(pr),
    "issue_linked": False,
    "pr_state": "UNKNOWN",
    "merged_at": None,
    "pr_head_sha": None,
    "merge_commit_sha": None,
    "gate_head_sha": gate_head_sha or None,
    "gate_head_matches_pr_head": False,
    "gate_result_met": False,
    "gate_result_source": "unavailable",
    "review_decision": "UNKNOWN",
    "checks": {"total": 0, "success": 0, "failure": 0, "other": 0},
    "commit_count": None,
    "merge_gate_passed": False,
    "acceptance_verified": False,
    "verified_completion": False,
    "verification_source": "wrap_merge_gate_and_ac_plus_gh_pr_view" if gate_passed == "1" else "explicit_link_only",
}
try:
    import re
    from urllib.parse import urlparse
    data = json.loads(raw)
    if not isinstance(data,dict) or data.get("number")!=int(pr): raise ValueError("PR identity mismatch")
    if data.get("url"):
        url=urlparse(data["url"])
        if url.path.rstrip("/").lower()!=f"/{repo}/pull/{pr}".lower(): raise ValueError("PR repository mismatch")
    try: gate=json.loads(gate_result)
    except Exception: gate={}
    ci=gate.get("ci_status",{}) if isinstance(gate,dict) else {}
    gate_valid=bool(isinstance(gate,dict) and gate.get("met") is True and gate.get("missing")==[]
                    and isinstance(ci,dict) and ci.get("failing")==0 and ci.get("in_progress")==0
                    and gate.get("unresolved_thread_count")==0 and isinstance(gate.get("head_sha"),str)
                    and re.fullmatch(r"[a-fA-F0-9]{40}",gate["head_sha"])
                    and gate["head_sha"].lower()==gate_head_sha.lower())
    evidence["gate_result_met"]=gate_valid and gate_passed=="1"
    evidence["gate_result_source"]="merge-gate.sh.result" if gate_valid else "unavailable_or_invalid"
    evidence["merge_gate_passed"]=evidence["gate_result_met"]
    evidence["acceptance_verified"]=evidence["gate_result_met"]
    evidence["pr_state"] = data.get("state") or "UNKNOWN"
    evidence["merged_at"] = data.get("mergedAt")
    evidence["pr_head_sha"] = data.get("headRefOid")
    merge_commit = data.get("mergeCommit")
    evidence["merge_commit_sha"] = merge_commit.get("oid") if isinstance(merge_commit, dict) else None
    evidence["gate_head_matches_pr_head"] = bool(
        gate_passed == "1" and gate_head_sha and data.get("headRefOid") and
        gate_head_sha.lower() == data["headRefOid"].lower()
    )
    evidence["review_decision"] = data.get("reviewDecision") or "UNKNOWN"
    linked = data.get("closingIssuesReferences") or []
    linked_matches = []
    for ref in linked:
        if not isinstance(ref, dict) or str(ref.get("number")) != issue:
            continue
        repository = ref.get("repository") or {}
        owner_repo = repository.get("nameWithOwner") if isinstance(repository, dict) else None
        if not owner_repo and isinstance(repository,dict):
            owner=repository.get("owner") or {}
            if isinstance(owner,dict) and owner.get("login") and repository.get("name"):
                owner_repo=owner["login"]+"/"+repository["name"]
        linked_matches.append(bool(owner_repo and owner_repo.lower() == repo.lower()))
    evidence["issue_linked"] = any(linked_matches)
    checks = data.get("statusCheckRollup") or []
    buckets = {"success": 0, "nonblocking":0, "failure": 0, "other": 0}
    for check in checks:
        status = str(check.get("conclusion") or check.get("state") or "").upper()
        if check.get("__typename")=="CheckRun" and check.get("status")!="COMPLETED":
            buckets["other"]+=1
        elif status in ("SUCCESS",):
            buckets["success"] += 1
        elif status in ("NEUTRAL","SKIPPED","CANCELLED"):
            buckets["nonblocking"]+=1
        elif status in ("FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"):
            buckets["failure"] += 1
        else:
            buckets["other"] += 1
    evidence["checks"] = {"total": len(checks), **buckets}
    commits = data.get("commits")
    count=data.get("commit_count")
    evidence["commit_count"] = count if type(count) is int and count>=0 else (len(commits) if isinstance(commits,list) else None)
    evidence["verified_completion"] = bool(
        evidence["gate_result_met"] and evidence["gate_head_matches_pr_head"] and evidence["issue_linked"] and
        evidence["pr_state"] == "MERGED" and evidence["merged_at"] and
        checks and buckets["success"]+buckets["nonblocking"] == len(checks)
    )
except Exception:
    pass
print(json.dumps(evidence, separators=(",", ":"), sort_keys=True))
PY
)"
  if [[ "$EVIDENCE_JSON" == *'"issue_linked":false'* && "$EVIDENCE_JSON" != *'"pr_state":"UNKNOWN"'* ]]; then
    echo "WARN: PR #$PR does not report the explicit issue link; correlation saved without verified outcome." >&2
  fi
fi

record_spend_correlation "$SESSION_ID" "$REPO_ROOT" "$REPO" "$ISSUE" "$PR" \
  "$TASK_ID" "$AGENT_ID" "$SOURCE" "$EVIDENCE_JSON" || true
exit 0
