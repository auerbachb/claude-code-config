#!/usr/bin/env python3
"""Metadata-only report for legacy TSV and schema-v2/v3 spend telemetry."""

import json
import math
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone


def parse_ts(value):
    try:
        parsed=datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc) if parsed.tzinfo else None
    except Exception:
        return None


def number(value):
    try:
        parsed=int(value) if value != "" else None
        return parsed if parsed is None or parsed>=0 else None
    except (TypeError, ValueError):
        return None


def fmt_number(value):
    return "n/a" if value is None else f"{value:,}"


def parse_row(parts, line_number):
    version = number(parts[8]) if len(parts) > 8 else 1
    row = {
        "ts_str": parts[0] if parts else "",
        "event_type": parts[1] if len(parts) > 1 else "",
        "exec_type": parts[2] if len(parts) > 2 else "unknown",
        "model_tier": parts[3] if len(parts) > 3 and parts[3] else "unknown",
        "agent_type": parts[4] if len(parts) > 4 else "",
        "session_id": parts[5] if len(parts) > 5 else "",
        "agent_id": parts[6] if len(parts) > 6 else "",
        "legacy_tokens": number(parts[7].strip()) if len(parts) > 7 else None,
        "schema_version": version or 1,
        "event_key": parts[9] if len(parts) > 9 else "",
        "repo_root": parts[10] if len(parts) > 10 else "",
        "phase": parts[11] if len(parts) > 11 and parts[11] else "unknown",
        "requested_model": parts[12] if len(parts) > 12 else "",
        "requested_source": parts[13] if len(parts) > 13 else "unavailable",
        "actual_model": parts[14] if len(parts) > 14 else "",
        "actual_source": parts[15] if len(parts) > 15 else "unavailable",
        "input_tokens": number(parts[16]) if len(parts) > 16 else None,
        "output_tokens": number(parts[17]) if len(parts) > 17 else None,
        "cache_read_tokens": number(parts[18]) if len(parts) > 18 else None,
        "cache_write_tokens": number(parts[19]) if len(parts) > 19 else None,
        "cost_usd": parts[20] if len(parts) > 20 else "",
        "cost_source": parts[21] if len(parts) > 21 else "unsupported",
        "task_id": parts[22] if len(parts) > 22 else "",
        "lifecycle": parts[23] if len(parts) > 23 else "unknown",
        "transcript_scope": parts[24] if len(parts) > 24 else "",
        "usage_source": parts[25] if len(parts) > 25 else "unavailable",
        "evidence_json": parts[26] if len(parts) > 26 else "",
        "line": line_number,
    }
    try:
        row["evidence"] = json.loads(row["evidence_json"]) if row["evidence_json"] else {}
    except (TypeError, ValueError):
        row["evidence"] = {}
    if not isinstance(row["evidence"],dict): row["evidence"]={}
    row["evidence"]["repo_slug"]=str(row["evidence"].get("repo_slug") or "").lower()
    for key in ("session_id","actual_model"):
        if row[key] in ("unknown","default","null","undefined"): row[key]=""
    row["ts"] = parse_ts(row["ts_str"])
    return row


def merge_message(old, new):
    """Transcript entries repeat provider-message usage, never additive deltas."""
    merged=dict(old)
    for key in ("input_tokens","output_tokens","cache_read_tokens","cache_write_tokens"):
        if new.get(key) is not None: merged[key]=new[key]
    for key in ("actual_model","actual_source","requested_model","requested_source"):
        if new.get(key) and new[key] not in ("unavailable","unknown"): merged[key]=new[key]
    # A child transcript provides the explicit worker/phase for a parent mirror.
    if new.get("agent_id") and not old.get("agent_id"):
        for key in ("agent_id","agent_type","exec_type","phase","transcript_scope"):
            merged[key]=new[key]
    if merged.get("phase")=="unknown" and new.get("phase")!="unknown": merged["phase"]=new["phase"]
    fields=[merged.get(k) for k in ("input_tokens","output_tokens","cache_read_tokens","cache_write_tokens")]
    merged["legacy_tokens"]=sum(fields) if all(v is not None for v in fields) else None
    return merged


def dedupe(rows):
    seen={}; result=[]
    for row in rows:
        key=row["event_key"] if row["schema_version"]>=2 else ""
        # Correlations and task lifecycle identities are stable, scoped records.
        identity=row["session_id"] or row["evidence"].get("transcript_id") or ("unscoped-line:"+str(row["line"]))
        unique=(identity,row["evidence"].get("repo_slug") or row["evidence"].get("repo",""),row["agent_id"],row["transcript_scope"],row["event_type"],key)
        if key and unique in seen:
            idx=seen[unique]
            if row["event_type"]=="assistant_message": result[idx]=merge_message(result[idx],row)
            elif row["event_type"] in ("task_correlation","transcript_scan"): result[idx]=row
            continue
        if key: seen[unique]=len(result)
        result.append(row)
    return result


def unique_messages(rows):
    """Preserve raw source scopes, count one provider message in usage totals."""
    seen={}; result=[]
    for row in rows:
        identity_source=row["evidence"].get("message_identity_source")
        if row["schema_version"]>=3 and identity_source not in ("message.id","transcript.uuid"):
            # The raw row remains in the log, but without a stable source ID we
            # cannot know whether another transcript contains the same message.
            continue
        # Unknown sessions cannot establish parent/child identity.
        key=(row["session_id"],row["evidence"].get("repo_slug", ""),row["event_key"],
             "" if row["session_id"] else (row["agent_id"],row["transcript_scope"],row["evidence"].get("transcript_id") or row["line"]))
        if row["event_key"] and key in seen:
            idx=seen[key];result[idx]=merge_message(result[idx],row)
        else:
            seen[key]=len(result);result.append(row)
    return result


def render_legacy(rows, heading):
    print(f"### {heading}\n")
    if not rows:
        print("No legacy events in this window.\n")
        return
    seen = {row["model_tier"] or "unknown" for row in rows}
    order = [tier for tier in ("opus", "sonnet", "haiku", "fable", "unknown") if tier in seen]
    order += sorted(seen - set(order))
    counts = Counter(
        (row["exec_type"] if row["exec_type"] in ("thread", "inline") else "unknown",
         row["model_tier"] or "unknown")
        for row in rows
    )
    thread = sum(counts["thread", tier] for tier in order)
    inline = sum(counts["inline", tier] for tier in order)
    print(f"**Total events:** {len(rows)} (thread: {thread}, inline: {inline})\n")
    print("| exec_type | " + " | ".join(order) + " | total |")
    print("| --- | " + " | ".join("---:" for _ in order) + " | ---: |")
    for exec_type in ("thread", "inline", "unknown"):
        values = [counts[exec_type, tier] for tier in order]
        total = sum(values)
        if total or exec_type != "unknown":
            print(f"| {exec_type} | " + " | ".join(map(str, values)) + f" | {total} |")
    print("\n| model_tier | events with legacy token count | token sum |\n| --- | ---: | ---: |")
    for tier in order:
        group = [row for row in rows if row["model_tier"] == tier]
        bearing = [row["legacy_tokens"] for row in group if row["legacy_tokens"] is not None]
        total = sum(bearing) if bearing else None
        print(f"| {tier} | {len(bearing)}/{len(group)} | {fmt_number(total)} |")
    print("\nLegacy inline tiers came from agent definitions, not runtime attribution.\n")


def scope_key(row):
    return (row["session_id"], row["agent_id"], row["exec_type"], row["evidence"].get("repo_slug", ""))


def load_estimate_log():
    """Read the existing per-PR estimate ledger without inventing task joins."""
    path = os.path.expanduser("~/.claude/estimate-log.jsonl")
    estimates = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as stream:
            for raw in stream:
                try:
                    row = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if not isinstance(row,dict): continue
                repo, pr = row.get("repo"), row.get("pr")
                if repo and pr:
                    estimates[(str(repo).lower(), str(pr))] = row
    except OSError:
        pass
    return estimates


def verified_pr(evidence):
    import re
    head=evidence.get("pr_head_sha")
    gate=evidence.get("gate_head_sha")
    checks=evidence.get("checks") or {}
    if not isinstance(checks,dict) or any(type(checks.get(k,0)) is not int or checks.get(k,0)<0 for k in ("total","success","nonblocking","failure","other")): return False
    return bool(evidence.get("verified_completion") is True and evidence.get("gate_result_met") is True
                and evidence.get("gate_result_source")=="merge-gate.sh.result"
                and isinstance(head,str) and isinstance(gate,str) and re.fullmatch(r"[a-fA-F0-9]{40}",head)
                and head.lower()==gate.lower() and evidence.get("issue_linked") is True
                and evidence.get("pr_state")=="MERGED" and parse_ts(evidence.get("merged_at") or "")
                and isinstance(checks,dict) and checks.get("total",0)>0
                and checks.get("success",0)+checks.get("nonblocking",0)==checks.get("total"))


def render_v2(v2, heading):
    print(f"### {heading}\n")
    source_messages=[row for row in v2 if row["event_type"]=="assistant_message"]
    unidentified=sum(1 for row in source_messages if row["schema_version"]>=3 and row["evidence"].get("message_identity_source") not in ("message.id","transcript.uuid"))
    messages=unique_messages(source_messages)
    mirrors_collapsed=len(source_messages)-unidentified-len(messages)
    print(f"Transcript source records: {len(source_messages)}; parent/child mirrors collapsed: {mirrors_collapsed}; unidentifiable observations excluded from message totals: {unidentified}. Counts below use stable message.id/uuid identities, not additive transcript copies.\n")
    if unidentified:
        print("Unidentifiable assistant-message observations remain in raw telemetry, but their usage is excluded because parent/child duplicates cannot be recognized without a stable message ID or transcript UUID.\n")
    scans={}
    for row in v2:
        if row["event_type"]=="transcript_scan": scans[scope_key(row)+(row["evidence"].get("transcript_id", ""),)]=row
    if scans:
        complete=sum(row["usage_source"]=="transcript_scan:complete" for row in scans.values())
        print(f"Latest transcript scan coverage: {complete}/{len(scans)} scopes complete; {len(scans)-complete} pending/partial. Observed usage is not total usage for incomplete scopes.\n")
    source_rows = Counter(
        (row["event_type"], row["exec_type"], row["usage_source"] or "unavailable")
        for row in v2 if row["event_type"] != "assistant_message"
    )
    print("| Non-message event | Execution type | Source status | Records |\n| --- | --- | --- | ---: |")
    for (event_type, exec_type, source_status), count in sorted(source_rows.items()):
        print(f"| {event_type} | {exec_type} | {source_status} | {count} |")
    print()
    actual_known = sum(bool(row["actual_model"]) for row in messages)
    print(f"**Assistant-message denominator:** {len(messages)} unique message record(s).")
    print(f"**Actual model:** {actual_known}/{len(messages)} known; requested model is retained separately with provenance.\n")
    attribution = Counter(
        (row["requested_model"] or "unknown", row["requested_source"] or "unavailable",
         row["actual_model"] or "unknown", row["actual_source"] or "unavailable")
        for row in messages
    )
    print("| Requested default | Requested source | Actual model | Actual source | Messages |\n| --- | --- | --- | --- | ---: |")
    for (requested, requested_source, actual, actual_source), count in sorted(attribution.items()):
        print(f"| {requested} | {requested_source} | {actual} | {actual_source} | {count} |")
    print()
    print("| Field | Available records / denominator | Sum of available values |\n| --- | ---: | ---: |")
    for label, key in (
        ("Input tokens", "input_tokens"),
        ("Output tokens", "output_tokens"),
        ("Cache-read tokens", "cache_read_tokens"),
        ("Cache-write tokens", "cache_write_tokens"),
    ):
        values = [row[key] for row in messages if row[key] is not None]
        print(f"| {label} | {len(values)}/{len(messages)} | {fmt_number(sum(values) if values else None)} |")
    costs = []  # No supported billed per-event source is collected by this pipeline.
    print(f"| Authoritative billed cost | {len(costs)}/{len(messages)} | n/a (no supported per-event cost source) |\n")

    print("### Usage by phase and actual model\n")
    if not messages:
        print("No v2 transcript messages recorded yet; existing history is not backfilled.\n")
    else:
        groups = defaultdict(list)
        for row in messages:
            groups[(row["phase"], row["actual_model"] or "unknown")].append(row)
        print("| Phase | Actual model | Messages | Input | Output | Cache read | Cache write | Sum of observed spans (s) |")
        print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for (phase, model), group in sorted(groups.items()):
            def sum_field(name):
                values = [row[name] for row in group if row[name] is not None]
                return sum(values) if values else None

            by_run = defaultdict(list)
            for row in group:
                if row["ts"]:
                    by_run[scope_key(row) + (phase, model)].append(row["ts"])
            spans = [
                (max(values) - min(values)).total_seconds()
                for values in by_run.values()
                if len(values) > 1
            ]
            span = round(sum(spans)) if spans else None
            print(
                f"| {phase} | {model} | {len(group)} | {fmt_number(sum_field('input_tokens'))} "
                f"| {fmt_number(sum_field('output_tokens'))} | {fmt_number(sum_field('cache_read_tokens'))} "
                f"| {fmt_number(sum_field('cache_write_tokens'))} | {fmt_number(span)} |"
            )
        print()

    lifecycle = [row for row in v2 if row["event_type"] in ("task_created", "task_completed")]
    # Runtime task IDs are scoped to a session; never merge equal IDs across
    # sessions into one apparent task.
    created={(r["session_id"],r["evidence"].get("repo_slug", "").lower(),r["task_id"]) for r in lifecycle if r["event_type"]=="task_created" and r["task_id"] and r["session_id"]}
    completed={(r["session_id"],r["evidence"].get("repo_slug", "").lower(),r["task_id"]) for r in lifecycle if r["event_type"]=="task_completed" and r["task_id"] and r["session_id"]}
    # Hook agent_id is the creator/completer, not an assignee mapping.
    explicit=[r for r in v2 if r["event_type"]=="task_correlation" and r["task_id"] and r["agent_id"]]
    task_workers=defaultdict(set)
    for r in explicit:
        repo=str(r["evidence"].get("repo") or "").lower()
        task_workers[(r["session_id"],repo,r["agent_id"])].add(r["task_id"])
    unique_worker_task_mappings=sum(map(len,task_workers.values()))
    print("### Task and outcome joins\n")
    print(f"TaskCreated IDs: {len(created)}; TaskCompleted IDs: {len(completed)}; unique explicit session/repo/worker-to-task mappings: {unique_worker_task_mappings}.")
    print(f"Unscoped task lifecycle events: {sum(not r['session_id'] for r in lifecycle)}; they cannot establish unique task identity.")
    print("TaskCompleted means the runtime marked a task complete; it does not verify acceptance criteria or passing tests.")
    print("Task subjects/descriptions are discarded. Issue/PR joins use only explicit correlation records; ambiguous links stay unknown.\n")

    correlations = [row for row in v2 if row["event_type"] == "task_correlation"]
    pr_by_issue = defaultdict(dict)
    for row in correlations:
        evidence = row["evidence"]
        repo, issue, pr = evidence.get("repo"), evidence.get("issue"), evidence.get("pr")
        if not (repo and issue and pr):
            continue
        if evidence.get("pr_state") not in (None, "UNKNOWN") and not evidence.get("issue_linked"):
            continue
        pr_by_issue[(str(repo).lower(), str(issue))][str(pr)] = row

    resolved_links = []
    unresolved_links = []
    for row in correlations:
        evidence = row["evidence"]
        if not row["session_id"] or row["session_id"] == "unknown":
            continue
        if evidence.get("pr"):
            resolved_links.append(row)
            continue
        key = (str(evidence.get("repo", "")).lower(), str(evidence.get("issue", "")))
        matches = pr_by_issue.get(key, {})
        if len(matches) == 1:
            pr_row = next(iter(matches.values()))
            joined = dict(row)
            joined["evidence"] = dict(pr_row["evidence"])
            joined["evidence"]["correlation_join"] = "explicit repo+issue; unique PR"
            resolved_links.append(joined)
        else:
            unresolved_links.append((row, "ambiguous PR mapping" if len(matches) > 1 else "no PR evidence"))

    estimates=load_estimate_log()
    link_map={}
    for link in resolved_links:
        ev=link["evidence"]
        link_map[(link["session_id"],str(ev.get("repo", "")).lower(),str(ev.get("pr", "")),link["task_id"],link["agent_id"])]=link
    resolved_links=list(link_map.values())
    session_prs=defaultdict(set)
    worker_prs=defaultdict(set)
    for link in resolved_links:
        ev=link["evidence"]
        session_prs[(link["session_id"],str(ev.get("repo", "")).lower())].add(str(ev.get("pr", "")))
        if link["agent_id"]: worker_prs[(link["session_id"],str(ev.get("repo", "")).lower(),link["agent_id"])].add(str(ev.get("pr", "")))
    message_joined = set()
    verified_task_keys=set()
    verified_usage=[]
    print(f"Explicit session/issue correlation records: {len(correlations)}; links resolved to one PR: {len(resolved_links)}; links without a unique PR: {len(unresolved_links)}.")
    print("Usage rows join by exact session + repository slug, and by worker/task only when explicitly supplied; no branch/time inference is used.")
    print("\n| Repo | Issue | PR | Session | Task | Usage messages | Outcome | Gate head matches PR head | Review decision | Current checks | Merge SHA | Actual min | Commit rounds (proxy) |\n| --- | ---: | ---: | --- | --- | ---: | --- | --- | --- | --- | --- | ---: | ---: |")
    if not resolved_links:
        print("| n/a | n/a | n/a | n/a | n/a | 0 | unknown | unknown | unavailable | unavailable | n/a | n/a | n/a |")
    for link in resolved_links:
        evidence = link["evidence"]
        repo = str(evidence.get("repo") or "unknown")
        issue = str(evidence.get("issue") or "unknown")
        pr = str(evidence.get("pr") or "unknown")
        task_id, agent_id = link["task_id"], link["agent_id"]
        ambiguous=bool(agent_id and len(worker_prs[(link["session_id"],repo.lower(),agent_id)])>1) or (not agent_id and len(session_prs[(link["session_id"],repo.lower())])>1) or bool(task_id and len(task_workers[(link["session_id"],repo.lower(),agent_id)])>1)
        assignment_unknown=bool(task_id and not agent_id)
        usage_unknown=ambiguous or assignment_unknown
        linked_messages=[] if usage_unknown else [r for r in messages if r["session_id"]==link["session_id"] and r["evidence"].get("repo_slug", "").lower()==repo.lower() and (not agent_id or r["agent_id"]==agent_id)]
        message_joined.update((r["session_id"],r["evidence"].get("repo_slug", ""),r["event_key"]) for r in linked_messages)
        task_complete=bool(task_id and (link["session_id"],repo.lower(),task_id) in completed)
        verified=bool(task_complete and verified_pr(evidence))
        task_key=(repo.lower(),pr,link["session_id"],task_id,agent_id)
        if verified:
            verified_task_keys.add(task_key)
            verified_usage.append((task_key,linked_messages,usage_unknown))
        if task_id:
            outcome = "TaskCompleted + merged gate verified" if verified else ("TaskCompleted; outcome unverified" if task_complete else "task completion unavailable")
        else:
            outcome = "merged gate verified; session-level" if verified_pr(evidence) else ("merged; unverified session-level" if evidence.get("pr_state") == "MERGED" else "PR outcome unknown")
        checks = evidence.get("checks") or {}
        if not isinstance(checks,dict): checks={}
        nonblocking=f"; {checks['nonblocking']} nonblocking" if checks.get("nonblocking") else ""
        check_text = f"{checks.get('success', 0)}/{checks.get('total', 0)} success{nonblocking}; {checks.get('other', 0)} unknown"
        gate_head_match = "yes" if evidence.get("gate_head_matches_pr_head") else ("no" if evidence.get("gate_head_sha") else "unavailable")
        merge_sha = evidence.get("merge_commit_sha") or "unavailable"
        estimate = estimates.get((repo.lower(), pr), {})
        actual_min = estimate.get("actual_min")
        actual_text = f"{float(actual_min):.1f}" if type(actual_min) in (int,float) and math.isfinite(actual_min) and actual_min>=0 else "n/a"
        rounds = estimate.get("rounds")
        rounds_text = str(rounds) if type(rounds) is int and rounds>=0 else "n/a"
        print(f"| {repo} | {issue} | {pr} | {link['session_id']} | {task_id or 'session'} | {'unknown' if usage_unknown else len(linked_messages)} | {outcome} | {gate_head_match} | {evidence.get('review_decision', 'unavailable')} | {check_text} | {merge_sha} | {actual_text} | {rounds_text} |")
    print(f"\nVerified task/PR joins: {len(verified_task_keys)}; linked assistant-message records: {len(message_joined)}/{len(messages)}.")
    print("\n### Usage per verified completed task\n")
    print("| Repo / PR / task | Observed messages | Input (available/observed; sum) | Output | Cache read | Cache write | Billed cost |")
    print("| --- | ---: | --- | --- | --- | --- | --- |")
    for key,group,ambiguous in verified_usage:
        cells=[]
        for name in ("input_tokens","output_tokens","cache_read_tokens","cache_write_tokens"):
            values=[r[name] for r in group if r[name] is not None]
            cells.append("unknown" if ambiguous else f"{len(values)}/{len(group)}; {fmt_number(sum(values) if values else None)}")
        print(f"| {key[0]} / PR {key[1]} / {key[3]} | {'unknown' if ambiguous else len(group)} | "+" | ".join(cells)+" | unavailable |")
    print("Tasks with no explicit worker mapping and ambiguous multi-PR/reused worker-task mappings retain unknown usage allocation; task completion can still be verified by session/repo/task ID. Hook actor IDs do not imply task assignment.\n")
    print("Estimate-log actual minutes are elapsed-time records keyed by exact repo+PR. Its rounds field counts commits, not paid reviewer rounds or CI retries.")
    print("Current GitHub check rollup is a snapshot, not retry history. Exact paid review rounds, historical CI reruns, and escalation reasons remain unavailable; cost remains unavailable.")
    if unresolved_links:
        print("\nUnresolved explicit issue links:")
        for row, reason in unresolved_links:
            evidence = row["evidence"]
            print(f"- {evidence.get('repo', 'unknown')} issue {evidence.get('issue', 'unknown')} session {row['session_id']}: {reason}")
    print()

    print("### Source limitations\n")
    print("- Hooks expose model/session/task identifiers but no token or billed-cost fields; transcript assistant-message metadata is the usage source.")
    print("- Issue/PR and merge-gate correlation requires explicit workflow records; verified outcomes require the observed gate SHA to match the merged PR head. The estimate ledger has PR/issue/elapsed/commit-round data but no session/task ID. Session-state PR records likewise have no session join key.")
    print("- Missing model, usage component, cost, or lifecycle value is unknown, never zero. Historical rows are not reconstructed.")
    print("- The report is observational only and never feeds quota, budget, or dispatch gates.\n")


def render(days, path):
    if not os.path.exists(path):
        print("## Spend / Thread-Type Telemetry Report\n")
        print(f"No telemetry log found at `{path}`.")
        print("The log is created automatically when the spend-telemetry hooks fire.")
        print("Run a new Claude Code session to generate the first record.")
        return

    records = []
    with open(path, encoding="utf-8", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            parts = raw.rstrip("\n").split("\t")
            if len(parts) >= 3:
                records.append(parse_row(parts, line_number))
    records = dedupe(records)
    now = datetime.now(timezone.utc)
    tracking_start = min((row["ts"] for row in records if row["ts"]), default=None)
    print("## Spend / Thread-Type Telemetry Report\n")
    print(f"> Tracking since: `{tracking_start.strftime('%Y-%m-%d') if tracking_start else 'unknown'}`")
    print("> Data source: `~/.claude/spend-telemetry.log`")
    print(f"> Generated: `{now.strftime('%Y-%m-%dT%H:%M:%SZ')}`")
    print(">")
    print("> Metadata-only report. Missing values stay unknown; this report does not estimate cost or gate work.\n")

    legacy = [row for row in records if row["schema_version"] < 2]
    render_legacy(legacy, "Legacy event coverage (pre-v2 schema)")

    all_v2 = [row for row in records if row["schema_version"] >= 2]
    render_v2(all_v2, "All-time schema-v2/v3 usage coverage")
    v2 = all_v2
    if days:
        try: cutoff = now - timedelta(days=days)
        except OverflowError: cutoff = datetime.min.replace(tzinfo=timezone.utc)
        legacy = [row for row in legacy if row["ts"] and row["ts"] >= cutoff]
        v2 = [row for row in all_v2 if row["ts"] and row["ts"] >= cutoff]
        print(f"### Last {days} days (from {cutoff.strftime('%Y-%m-%d')} UTC)\n")
        render_legacy(legacy, f"Last {days} day(s) legacy event coverage")
        render_v2(v2, f"Last {days} day(s) schema-v2/v3 usage coverage")
    inline_agents = Counter(
        row["agent_type"] for row in records
        if row["schema_version"] < 2 and row["exec_type"] == "inline" and row["agent_type"]
    )
    if inline_agents:
        print("### Inline agent-type inventory\n")
        print("| agent_type | legacy invocations |\n| --- | ---: |")
        for agent_type, count in inline_agents.most_common():
            print(f"| {agent_type} | {count} |")
        print()
    print("---\n")
    print("*Pipeline and schema notes: `.claude/reference/spend-telemetry-pipeline.md`*")


if __name__ == "__main__":
    render(int(sys.argv[1]), sys.argv[2])
