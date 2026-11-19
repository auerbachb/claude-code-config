#!/usr/bin/env python3
"""Record refill slot counts through session-state.sh and render the board notice."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys


LABELS = {
    "chained": "chained",
    "undeclared": "undeclared",
    "nothing_eligible": "nothing eligible",
    "paused": "paused",
    "paused_state_unreadable": "paused (state unreadable)",
    "paused_pipeline_failures": "paused (pipeline failures)",
    "paused_budget_reached": "paused (budget reached)",
    "paused_budget_unknown": "paused (budget unknown)",
    "paused_priority_unreadable": "paused (priority unreadable)",
    "horizon": "horizon",
    "deadline": "deadline",
    "repo_wide_cap": "repo-wide cap",
    "refill_missed": "refill_missed",
    "launch_unknown": "launch outcome unknown",
    "eligible_remaining": "eligible work remains",
}
GLOBAL_GATES = {reason for reason in LABELS if reason.startswith("paused")} | {"horizon", "deadline", "repo_wide_cap"}
CANDIDATE_GATES = {"chained", "undeclared", "deadline", "repo_wide_cap", "launch_unknown"}
STARTED = {"launched", "launch_unconfirmed"}
OUTCOMES = STARTED | CANDIDATE_GATES | {"eligible", "ineligible"}
HORIZONS = {"clear", "approaching", "critical", "unknown"}
COUNT_FIELDS = ("limit", "running", "merge_ready_or_phase_c", "queued")
SESSION_HISTORY_LIMIT = 48
REPO_HISTORY_LIMIT = 96
SESSION_LIMIT = 32


def compact(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def counts_from(data):
    if not isinstance(data, dict):
        raise ValueError("expected an object")
    counts = {field: data.get(field) for field in COUNT_FIELDS}
    if any(type(value) is not int or value < 0 for value in counts.values()):
        raise ValueError("slot counts must be nonnegative integers")
    if not counts["limit"] or counts["merge_ready_or_phase_c"] > counts["running"]:
        raise ValueError("invalid pipeline limit or Phase C count")
    return counts


def make_census(data):
    counts = counts_from(data)
    gate, horizon = data.get("global_gate"), data.get("horizon_status")
    if gate is not None and gate not in GLOBAL_GATES:
        raise ValueError("unrecognized global gate")
    if horizon is not None and horizon not in HORIZONS:
        raise ValueError("unrecognized horizon status")
    if gate == "horizon" and horizon not in {"approaching", "critical", "unknown"}:
        raise ValueError("a held horizon needs its observed status")
    rows = data.get("candidates")
    if not isinstance(rows, list):
        raise ValueError("candidates must be a list")
    outcomes = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid candidate")
        issue, outcome = row.get("issue"), row.get("outcome")
        if type(issue) is not int or issue <= 0 or issue in outcomes or outcome not in OUTCOMES:
            raise ValueError("each candidate needs a unique issue number and a known outcome")
        outcomes[issue] = outcome

    empty = max(counts["limit"] - counts["running"], 0)
    reasons = dict.fromkeys(LABELS, 0)
    # Unknown or unconfirmed launch evidence cannot prove that no launch occurred.
    no_launch = not (set(outcomes.values()) & (STARTED | {"launch_unknown"}))
    if gate:
        reasons[gate] = empty
    else:
        eligible_reason = "refill_missed" if no_launch else "eligible_remaining"
        for outcome in outcomes.values():
            if not empty:
                break
            if outcome == "eligible":
                outcome = eligible_reason
            elif outcome not in CANDIDATE_GATES:
                continue
            reasons[outcome] += 1
            empty -= 1
        reasons["nothing_eligible"] = empty

    missed = (counts["running"] < counts["limit"] and not gate and no_launch
              and "eligible" in outcomes.values())
    # Record a missed refill even when earlier held candidates account for every slot.
    return {
        **counts,
        "reasons": reasons,
        "horizon_status": horizon,
        "refill_missed": bool(missed),
    }


def format_line(census):
    counts = counts_from(census)
    if counts["running"] >= counts["limit"]:
        return ""
    reasons = census.get("reasons")
    if not isinstance(reasons, dict) or set(reasons) != set(LABELS) or any(
        type(count) is not int or count < 0 for count in reasons.values()
    ) or sum(reasons.values()) != counts["limit"] - counts["running"]:
        raise ValueError("invalid persisted slot reasons")
    labels = dict(LABELS)
    if reasons["horizon"]:
        status = census.get("horizon_status")
        if status not in {"approaching", "critical", "unknown"}:
            raise ValueError("invalid persisted horizon status")
        labels["horizon"] = f"horizon ({status})"
    holds = [f"{reasons[reason]} {labels[reason]}" for reason in LABELS if reasons[reason]]
    if census.get("refill_missed") is True and not reasons["refill_missed"]:
        holds.append("refill_missed")
    return f"Board below limit · {counts['running']}/{counts['limit']} slots · {', '.join(holds)}"


def state_call(helper, repo, *args):
    # The state record is the evidence. Do not append its bounded history to the usage log on each tick.
    env = dict(os.environ, CLAUDE_SCRIPT_USAGE_LOG="0")
    return subprocess.run([str(helper), "--repo", repo, *args], capture_output=True, text=True, env=env)


def read_state(helper, repo, path):
    result = state_call(helper, repo, "--get-json", path)
    if result.returncode == 3:
        return None
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"session-state read exited {result.returncode}")
    return json.loads(result.stdout)


def retain_recent(records):
    sessions = sorted(records, key=lambda session: (records[session]["evaluated_at"], session))[-SESSION_LIMIT:]
    records = {session: records[session] for session in sessions}
    history = sorted(
        (entry["evaluated_at"], session, entry["seq"])
        for session, record in records.items()
        for entry in record["history"]
    )
    if len(history) <= REPO_HISTORY_LIMIT:
        return records
    retained = {(session, seq) for _, session, seq in history[-REPO_HISTORY_LIMIT:]}
    return {
        session: {**record, "history": [entry for entry in record["history"] if (session, entry["seq"]) in retained]}
        for session, record in records.items()
    }


def record(helper, repo, path, session, census):
    line = format_line(census)
    for _ in range(4):
        previous = read_state(helper, repo, path)
        if previous is not None and not isinstance(previous, dict):
            raise ValueError("invalid previous census records")
        sessions = previous or {}
        current = sessions.get(session)
        if current is None:
            prior_seq, history, prior_line = 0, [], None
        elif isinstance(current, dict):
            prior_seq, history, prior_line = current.get("seq"), current.get("history"), current.get("line")
            if type(prior_seq) is not int or prior_seq < 1 or not isinstance(history, list) or not isinstance(prior_line, str):
                raise ValueError("invalid previous census record")
        else:
            raise ValueError("invalid previous census record")
        entry = {
            **census,
            "seq": prior_seq + 1,
            "evaluated_at": datetime.now(timezone.utc).isoformat(),
        }
        updated = {**entry, "line": line, "history": (history + [entry])[-SESSION_HISTORY_LIMIT:]}
        payload = retain_recent({**sessions, session: updated})
        # Compare the repo census map so a prune never drops a concurrent session update.
        result = state_call(helper, repo, "--cas", path + "=" + compact(payload), "--expect", compact(previous))
        if result.returncode == 7:
            continue
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or f"session-state write exited {result.returncode}")
        if line and line != prior_line:
            print(line)
        return
    raise RuntimeError("session-state changed during every census write attempt")


def render(helper, repo, path, session):
    records = read_state(helper, repo, path)
    if records is None or records == {}:
        return
    if not isinstance(records, dict):
        raise ValueError("invalid census records")
    own = session is not None and session in records
    if own:
        selected = session
    else:
        selected = max(records, key=lambda key: (records[key]["evaluated_at"], key))
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,120}", selected):
        raise ValueError("invalid census session")
    line = format_line(records[selected])
    if line:
        suffix = "" if own else f" (recorded session {selected})"
        print(line + suffix)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--record", action="store_true", help="read evaluation JSON on stdin")
    mode.add_argument("--render", action="store_true", help="render the persisted record")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--session")
    parser.add_argument("--state-helper", type=Path, default=Path(__file__).resolve().parents[1] / "session-state.sh")
    args = parser.parse_args()
    repo = args.repo.lower()
    if not re.fullmatch(r"[a-z0-9_.-]+/[a-z0-9_.-]+", repo):
        parser.error("--repo must be OWNER/REPO")
    if (args.record and not args.session) or (args.session is not None and not re.fullmatch(r"[A-Za-z0-9_-]{1,120}", args.session)):
        parser.error("--session requires an exact session ID")
    path = f".repos[{compact(repo)}].slot_census"
    try:
        if args.record:
            record(args.state_helper, repo, path, args.session, make_census(json.load(sys.stdin)))
        else:
            render(args.state_helper, repo, path, args.session)
    except (OSError, RuntimeError, ValueError, TypeError, KeyError) as exc:
        print(f"pm-slot-census: {exc}", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
