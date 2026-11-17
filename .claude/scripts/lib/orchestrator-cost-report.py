#!/usr/bin/env python3
"""Read-only parent-thread cost report for one session (issue #2434).

Parent figures come from the main transcript's assistant usage. Worker figures
come from spend telemetry rows with a worker agent_id, deduplicated with the
V2 report's parse_row/unique_messages. Missing data is None (unknown), never 0.
Nothing here writes files or calls a provider.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
V2_PATH = os.path.join(HERE, "spend-telemetry-report-v2.py")

FIELDS = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")
TELEMETRY_TO_FIELD = {
    "input_tokens": "input_tokens",
    "cache_read_tokens": "cache_read_input_tokens",
    "cache_write_tokens": "cache_creation_input_tokens",
    "output_tokens": "output_tokens",
}
# Automated (non-user) leading wrappers; mirrors the list in .claude/hooks/unattended-digest.sh.
AUTOMATED_WRAPPERS = ("<task-notification>", "<ci-monitor-event>", "<scheduled-task", "<system-reminder>")
READ_LIKE_TOOLS = {"Read", "Grep", "Glob"}
MUTATING_TOOLS = {"Edit", "Write", "NotebookEdit", "Agent"}
READ_BASH_PREFIXES = ("git status", "git diff", "git log", "git show", "gh pr view", "gh pr checks",
                      "gh issue view", "ls", "cat", "head", "tail", "wc", "pwd", "grep", "rg")
# `gh api` (defaults to POST with fields) and `find` (-delete, -exec) can mutate, so they are not read-only prefixes.

CLASSES = ("worker_result_handling", "instruction_skill_load", "changed_nothing_checkin",
           "data_gathering", "user_reply", "other")


class ReportError(Exception):
    def __init__(self, name, message=""):
        super().__init__(message or name)
        self.name = name


def load_v2():
    spec = importlib.util.spec_from_file_location("spend_telemetry_report_v2", V2_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def resolve_session(args):
    for value in (args.session, os.environ.get("CLAUDE_CODE_SESSION_ID"), os.environ.get("CLAUDE_SESSION_ID")):
        if value and value not in ("default", "unknown"):
            return value
    raise ReportError("session_unknown", "no session identity given or in environment")


def resolve_transcript(args, session):
    if args.transcript:
        return args.transcript
    matches = []
    base = os.path.expanduser(args.projects_dir)
    if os.path.isdir(base):
        for entry in sorted(os.listdir(base)):
            candidate = os.path.join(base, entry, session + ".jsonl")
            if os.path.isfile(candidate):
                matches.append(candidate)
    if len(matches) > 1:
        raise ReportError("transcript_ambiguous", "more than one transcript matches the session")
    if not matches:
        raise ReportError("transcript_not_found", "no transcript for the session")
    return matches[0]


def read_transcript(path):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except PermissionError:
        raise ReportError("transcript_unreadable", "transcript cannot be read")
    except OSError:
        raise ReportError("transcript_not_found", "transcript cannot be opened")
    text = raw.decode("utf-8", errors="replace")
    lines = text.split("\n")
    partial_tail = not text.endswith("\n") and bool(lines[-1])
    if partial_tail:
        lines = lines[:-1]  # only complete newline-terminated lines
    records, malformed = [], 0
    for line in lines:
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        # A valid JSON value that is not an object (null, a number, a list) is not a transcript record.
        if isinstance(rec, dict):
            records.append(rec)
        else:
            malformed += 1
    return records, {"malformed_lines": malformed, "partial_tail": partial_tail}


def usage_of(message):
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None
    out = {}
    for field in FIELDS:
        value = usage.get(field)
        out[field] = value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None
    return out


def tool_uses(content):
    if not isinstance(content, list):
        return []
    return [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"]


def is_tool_result_only(content):
    return isinstance(content, list) and bool(content) and all(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def user_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                return b.get("text", "")
    return ""


SHELL_COMPOUND_CHARS = set(";|&<>`$\n")


# Options that write a file or run an external program even under a read-only subcommand.
WRITE_OPTIONS = ("--output", "-o", "--ext-diff", "--textconv", "--exec", "-delete")


def bash_is_read_only(command):
    cmd = (command or "").strip()
    # Redirections, pipes, command substitution and chaining disqualify a prefix match.
    if any(ch in SHELL_COMPOUND_CHARS for ch in cmd):
        return False
    if any(tok == o or tok.startswith(o + "=") for tok in cmd.split() for o in WRITE_OPTIONS):
        return False
    return any(cmd == p or cmd.startswith(p + " ") for p in READ_BASH_PREFIXES)


def refused_agent_ids(records):
    """tool_use IDs of Agent calls a PreToolUse hook refused before any worker started."""
    out = set()
    for rec in records:
        msg = rec.get("message") if isinstance(rec, dict) and isinstance(rec.get("message"), dict) else {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not (isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error")):
                continue
            text = json.dumps(b.get("content"))
            if "PreToolUse:Agent" in text and "hook error" in text:
                out.add(b.get("tool_use_id"))
    return out


def build_turns(records):
    """Group parent (non-sidechain) records into turns. Returns (turns, unallocated_msgs)."""
    turns, current, unallocated = [], None, []
    seen_ids = set()
    seen_entries = {}
    for rec in records:
        if rec.get("isSidechain"):
            continue
        msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
        if rec.get("type") == "user":
            content = msg.get("content")
            if is_tool_result_only(content):
                if current is not None:
                    current["results"].append(content)
                continue
            current = {"start_text": user_text(content), "automated": False, "assistant": {},
                       "results": [], "uses": []}
            text = current["start_text"].lstrip()
            current["automated"] = text.startswith(AUTOMATED_WRAPPERS)
            current["worker_notification"] = text.startswith("<task-notification>")
            current["skill_wrapper"] = "<command-name>" in text[:200]
            turns.append(current)
        elif rec.get("type") == "assistant":
            mid = msg.get("id") or rec.get("uuid")
            usage = usage_of(msg)
            model = msg.get("model") or rec.get("model") or ""
            if not mid:
                unallocated.append({"model": model, "usage": usage})
                continue
            if usage is None:
                # Keep identity and tool activity; unobserved usage stays None, so coverage is partial.
                usage = {f: None for f in FIELDS}
            if mid in seen_ids:
                # Repeated record for one provider message: usage counts once (latest non-null
                # observation per field), and tool activity from every record is kept.
                existing = seen_entries[mid]
                for f in FIELDS:
                    # Later non-null observation replaces the earlier one; nulls never erase values.
                    if usage[f] is not None:
                        existing["usage"][f] = usage[f]
                known = {u.get("id") for u in existing["uses"]}
                for u in tool_uses(msg.get("content")):
                    if u.get("id") not in known:
                        existing["uses"].append(u)
                        known.add(u.get("id"))
                        if current is not None and mid in current["assistant"]:
                            current["uses"].append(u)
                continue
            seen_ids.add(mid)
            entry = {"id": mid, "model": model, "usage": usage, "timestamp": rec.get("timestamp", ""),
                     "uses": tool_uses(msg.get("content"))}
            seen_entries[mid] = entry
            if current is None:
                unallocated.append(entry)
            else:
                current["assistant"][mid] = entry
                current["uses"].extend(entry["uses"])
    return turns, unallocated


def classify(turn):
    signals = set()
    uses = turn["uses"]
    names = [u.get("name", "") for u in uses]
    if turn.get("worker_notification"):
        signals.add("worker_result")
    if turn.get("skill_wrapper") or "Skill" in names:
        signals.add("skill_load")
    read_like = mutating = False
    for u in uses:
        name = u.get("name", "")
        if name in READ_LIKE_TOOLS:
            read_like = True
        elif name == "Bash" and bash_is_read_only((u.get("input") or {}).get("command", "")):
            read_like = True
        elif name in MUTATING_TOOLS or name == "Bash":
            mutating = True
        elif name == "Skill":
            continue
        else:
            mutating = True
    if read_like and not mutating:
        signals.add("read_like")
    if mutating:
        signals.add("mutating")
    if turn["automated"] and not turn.get("worker_notification") and not uses:
        signals.add("automated_no_tools")
    if turn["automated"] and not turn.get("worker_notification") and not mutating:
        signals.add("automated_read_only")
    if not turn["automated"] and not uses and turn["start_text"]:
        signals.add("user_no_tools")

    matches = []
    if "worker_result" in signals:
        matches.append("worker_result_handling")
    if "skill_load" in signals:
        matches.append("instruction_skill_load")
    if "automated_read_only" in signals or "automated_no_tools" in signals:
        matches.append("changed_nothing_checkin")
    if "read_like" in signals and "mutating" not in signals:
        matches.append("data_gathering")
    if "user_no_tools" in signals:
        matches.append("user_reply")
    primary = matches[0] if matches else "other"
    return primary, matches


def sum_usage(entries):
    totals = {f: None for f in FIELDS}
    observed = {f: 0 for f in FIELDS}
    for entry in entries:
        for f in FIELDS:
            v = entry["usage"][f]
            if v is None:
                continue
            observed[f] += 1
            totals[f] = (totals[f] or 0) + v
    return totals, observed


def figure(totals, observed, n_total, limitations):
    """Return token figures with labels: known_subtotal when limitations apply, else complete_total."""
    label = "known_subtotal" if limitations else "complete_total"
    out = {}
    for f in FIELDS:
        if totals[f] is None or observed[f] == 0:
            out[f] = {"value": None, "label": "unknown", "observed": observed[f], "messages": n_total}
        else:
            partial = observed[f] < n_total
            out[f] = {"value": totals[f], "label": "known_subtotal" if (partial or limitations) else label,
                      "observed": observed[f], "messages": n_total}
    all_known = all(out[f]["value"] is not None for f in FIELDS)
    if all_known:
        s = sum(out[f]["value"] for f in FIELDS)
        out["sum"] = {"value": s, "label": "known_subtotal" if limitations or any(
            out[f]["observed"] < n_total for f in FIELDS) else "complete_total"}
    else:
        out["sum"] = {"value": None, "label": "unknown"}
    return out


def build_report(args):
    session = resolve_session(args)
    transcript = resolve_transcript(args, session)
    records, tail_info = read_transcript(transcript)
    # A transcript that names a different session is rejected rather than reported under this one.
    recorded = {r.get("sessionId") for r in records if isinstance(r, dict) and r.get("sessionId")}
    if any(sid != session for sid in recorded):
        raise ReportError("transcript_session_mismatch", "transcript records name a different session")
    limitations = []
    if tail_info["malformed_lines"]:
        limitations.append("malformed_transcript_lines")
    if tail_info["partial_tail"]:
        limitations.append("partial_transcript_tail")

    turns, unallocated = build_turns(records)

    # Parent message observations from the transcript.
    parent_entries = []
    for t in turns:
        parent_entries.extend(t["assistant"].values())
    parent_entries.extend(e for e in unallocated if e.get("id"))
    # Usage-bearing observations without a message ID cannot be deduplicated: keep them out of
    # the sums and mark the parent subtotal as incomplete.
    if any(e.get("id") is None and e.get("usage") is not None for e in unallocated):
        limitations.append("unidentified_usage_messages")

    # Worker observations and the telemetry parent rows from the spend log.
    worker_entries = defaultdict(list)
    worker_ids_telemetry = set()
    log_present = os.path.isfile(os.path.expanduser(args.log))
    if not log_present:
        limitations.append("telemetry_log_absent")
    else:
        v2 = load_v2()
        rows = []
        try:
            with open(os.path.expanduser(args.log), encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) < 6 or parts[5] != session:
                        continue
                    rows.append(v2.parse_row(parts, n))
        except OSError:
            raise ReportError("telemetry_log_unreadable", "telemetry log exists but cannot be read")
        # unique_messages drops schema-v3 rows without a stable message identity. Those rows
        # carry usage that cannot be deduplicated, so the worker side is marked partial.
        if any(r["event_type"] == "assistant_message" and r["schema_version"] >= 3
               and r["evidence"].get("message_identity_source") not in ("message.id", "transcript.uuid")
               for r in rows):
            limitations.append("unidentified_telemetry_rows")
        for row in v2.unique_messages(v2.dedupe(rows)):
            if row["event_type"] != "assistant_message":
                continue
            entry = {"id": row["event_key"], "model": row["actual_model"], "usage": {
                "input_tokens": row["input_tokens"], "cache_read_input_tokens": row["cache_read_tokens"],
                "cache_creation_input_tokens": row["cache_write_tokens"], "output_tokens": row["output_tokens"]}}
            if row["agent_id"]:
                worker_entries[row["agent_id"]].append(entry)
                worker_ids_telemetry.add(row["agent_id"])
        for row in rows:
            if str(row.get("usage_source", "")).startswith("unsupported"):
                limitations.append("unsupported_worker_row")
                break

    # Launched Agent calls in the transcript vs worker telemetry. A call a PreToolUse hook
    # refused never started a worker, so it is not expected to have telemetry.
    refused = refused_agent_ids(records)
    agent_ids = {u.get("id") for t in turns for u in t["uses"] if u.get("name") == "Agent"}
    agent_calls = len(agent_ids - refused)
    if agent_calls and len(worker_ids_telemetry) < agent_calls:
        limitations.append("unmatched_agent_calls")

    parent_totals, parent_obs = sum_usage(parent_entries)
    # A telemetry worker row whose message ID is also a parent transcript message is a mirror,
    # not a second worker message: keep the parent observation and drop the worker copy.
    parent_ids = {e["id"] for e in parent_entries if e.get("id")}
    for agent in list(worker_entries):
        worker_entries[agent] = [e for e in worker_entries[agent] if e.get("id") not in parent_ids]
    worker_flat = [e for lst in worker_entries.values() for e in lst]
    worker_totals, worker_obs = sum_usage(worker_flat)

    parent_fig = figure(parent_totals, parent_obs, len(parent_entries), limitations)
    worker_fig = figure(worker_totals, worker_obs, len(worker_flat), limitations)

    share = {"value": None, "reason": None}
    if not log_present:
        share["reason"] = "telemetry_log_absent"
    elif limitations:
        share["reason"] = "partial_data:" + ",".join(sorted(set(limitations)))
    elif parent_fig["sum"]["label"] != "complete_total" or worker_fig["sum"]["label"] != "complete_total":
        share["reason"] = "partial_data:field_coverage"
    else:
        total = parent_fig["sum"]["value"] + worker_fig["sum"]["value"]
        share["value"] = round(100.0 * parent_fig["sum"]["value"] / total, 1) if total else None
        if share["value"] is None:
            share["reason"] = "zero_total"

    # Turn classification and drivers.
    class_counts = {c: 0 for c in CLASSES}
    class_msgs = {c: 0 for c in CLASSES}
    ambiguous = 0
    class_tokens = {c: {f: None for f in FIELDS} for c in CLASSES}
    class_obs = {c: {f: 0 for f in FIELDS} for c in CLASSES}
    turn_rows = []
    for idx, t in enumerate(turns, 1):
        if not t["assistant"]:
            continue
        primary, matches = classify(t)
        if len(matches) > 1:
            ambiguous += 1
        class_counts[primary] += 1
        entries = list(t["assistant"].values())
        class_msgs[primary] += len(entries)
        totals, obs = sum_usage(entries)
        for f in FIELDS:
            if totals[f] is not None:
                class_tokens[primary][f] = (class_tokens[primary][f] or 0) + totals[f]
                class_obs[primary][f] += obs[f]
        tsum = sum(v for v in totals.values() if v is not None) if any(v is not None for v in totals.values()) else None
        first = entries[0]
        turn_rows.append({"turn": idx, "timestamp": first["timestamp"], "class": primary, "model": first["model"],
                          "fields": totals, "sum": tsum})

    drivers = []
    for c in CLASSES:
        vals = class_tokens[c]
        s = sum(v for v in vals.values() if v is not None) if any(v is not None for v in vals.values()) else None
        base = "known_subtotal" if limitations else "complete_total"
        fields = {}
        for f in FIELDS:
            if vals[f] is None:
                fields[f] = {"value": None, "label": "unknown"}
            else:
                partial = class_obs[c][f] < class_msgs[c]
                fields[f] = {"value": vals[f], "label": "known_subtotal" if partial else base}
        sum_partial = any(fields[f]["label"] != base for f in FIELDS)
        drivers.append({"class": c, "turns": class_counts[c],
                        "sum": {"value": s, "label": ("unknown" if s is None else
                                                       ("known_subtotal" if sum_partial else base))},
                        "fields": fields})
    drivers.sort(key=lambda d: -(d["sum"]["value"] or -1))

    by_model = defaultdict(list)
    for e in parent_entries:
        by_model[e.get("model") or "unknown"].append(e)
    model_split = {m: {"messages": len(v), **{k: sum_usage(v)[0][k] for k in FIELDS}} for m, v in by_model.items()}

    turn_rows.sort(key=lambda r: -(r["sum"] or -1))
    return {
        "session": {"id": session, "transcript_resolved": True},
        "coverage": {"limitations": sorted(set(limitations)), "telemetry_log_present": log_present,
                     "ambiguous_turns": ambiguous, "unallocated_messages": len(unallocated)},
        "parent": parent_fig,
        "workers": worker_fig,
        "worker_count": len(worker_entries),
        "by_model": model_split,
        "share": share,
        "turns": {"count": sum(class_counts.values()), "by_class": class_counts},
        "drivers": drivers,
        "top_turns": turn_rows[: args.top],
    }


def one_line(report):
    share = report["share"]
    if share["value"] is None:
        reason = share["reason"] or "unknown"
        p = report["parent"]["sum"]["value"]
        return f"Parent share: unknown — {reason}; parent known_subtotal {p if p is not None else 'unknown'} tokens"
    return f"Parent share: {share['value']}% of observed session tokens"


def render_markdown(report):
    lines = ["# Orchestrator cost report (read-only)", ""]
    lines.append("Figures are tokens. `unknown` means not measured; it is never zero.")
    lines.append("")
    for key, label in (("parent", "Parent"), ("workers", "Workers")):
        fig = report[key]
        lines.append(f"## {label}")
        for f in FIELDS + ("sum",):
            v = fig[f]
            lines.append(f"- {f}: {v['value'] if v['value'] is not None else 'unknown'} ({v['label']})")
        lines.append("")
    lines.append(f"Parent share: {report['share']['value'] if report['share']['value'] is not None else 'unknown'}"
                 f"{'' if report['share']['value'] is None else '%'}"
                 f" (reason: {report['share']['reason'] or 'none'})")
    lines.append("")
    lines.append("## Turns by class")
    for c, n in report["turns"]["by_class"].items():
        lines.append(f"- {c}: {n}")
    lines.append(f"- ambiguous: {report['coverage']['ambiguous_turns']}")
    lines.append("")
    lines.append("## Drivers")
    for d in report["drivers"]:
        s = d["sum"]["value"] if d["sum"]["value"] is not None else "unknown"
        cr = d["fields"]["cache_read_input_tokens"]["value"]
        lines.append(f"- {d['class']}: {s} tokens over {d['turns']} turns "
                     f"(cache reads shown separately: {cr if cr is not None else 'unknown'})")
    return "\n".join(lines) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser(description="Read-only parent-thread token report for one session.")
    p.add_argument("--session")
    p.add_argument("--transcript")
    p.add_argument("--projects-dir", default="~/.claude/projects")
    p.add_argument("--log", default="~/.claude/spend-telemetry.log")
    p.add_argument("--json", action="store_true")
    p.add_argument("--one-line", action="store_true")
    p.add_argument("--top", type=int, default=5)
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        # argparse exits 0 for --help and 2 for a usage error; keep both codes.
        return exc.code if isinstance(exc.code, int) else 2
    if args.top < 0:
        print("usage: --top must be >= 0", file=sys.stderr)
        return 2
    try:
        report = build_report(args)
    except ReportError as exc:
        print(exc.name, file=sys.stderr)
        return 1
    if args.one_line:
        print(one_line(report))
    elif args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        sys.stdout.write(render_markdown(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
