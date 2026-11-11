#!/usr/bin/env python3
"""Evaluate a PM report using an existing turn's board evidence."""
import argparse
import hashlib
import json
import re
import sys
import time


DEFAULT_REPORT_MINUTES = 30


def interval(section):
    settings = re.findall(r"(?m)^[ \t]*report_every_min[ \t]*:([^\r\n]*)$", section)
    if not settings:
        return DEFAULT_REPORT_MINUTES
    if len(settings) != 1 or not re.fullmatch(r"[0-9]+", settings[0].strip()):
        raise ValueError("report_every_min must be one nonnegative integer")
    return int(settings[0])


def issue_number(value):
    return type(value) is int and value > 0


def board_projection(board):
    if not isinstance(board, dict):
        raise ValueError("board must be an object")
    running = board.get("running")
    queued = board.get("queued")
    needs = board.get("needs")
    terminal = board.get("terminal")
    if not all(isinstance(rows, list) for rows in (running, queued, needs, terminal)):
        raise ValueError("board must include running, queued, needs and terminal arrays")

    if not all(isinstance(row, dict) and issue_number(row.get("issue"))
               and row.get("phase") in ("A", "B", "C")
               and (row.get("pr") is None or issue_number(row["pr"])) for row in running):
        raise ValueError("invalid working row")
    if not all(issue_number(number) for number in queued):
        raise ValueError("invalid queued issue")
    if not all(isinstance(row, dict) and issue_number(row.get("issue"))
               and isinstance(row.get("reason"), str) and row["reason"] for row in needs):
        raise ValueError("invalid owner-action row")
    if not all(isinstance(row, dict) and issue_number(row.get("issue"))
               and row.get("outcome") in ("merged", "blocked")
               and (row.get("pr") is None or issue_number(row["pr"]))
               and isinstance(row.get("key"), str) and row["key"] for row in terminal):
        raise ValueError("invalid terminal outcome")

    working = sorted(
        ({"issue": row["issue"], "phase": row["phase"], "pr": row.get("pr")} for row in running),
        key=lambda row: row["issue"],
    )
    needs_you = sorted(
        ({"issue": row["issue"], "reason": row["reason"]} for row in needs),
        key=lambda row: (row["issue"], row["reason"]),
    )
    outcomes = {
        row["key"]: {"issue": row["issue"], "outcome": row["outcome"], "pr": row.get("pr")}
        for row in terminal
    }
    if len(outcomes) != len(terminal):
        raise ValueError("duplicate terminal outcome keys")
    return {"working": working, "up_next": queued, "needs_you": needs_you}, outcomes


def evaluate(minutes, board, previous, now):
    if minutes == 0:
        return {"due": False, "reason": "disabled"}
    visible, outcomes = board_projection(board)
    if previous is None:
        previous = {"at": now, "digest": None, "reported": []}
        needs_baseline = bool(visible["working"] or visible["up_next"])
    else:
        needs_baseline = False
        if (not isinstance(previous, dict) or type(previous.get("at")) is not int
                or not 0 <= previous["at"] <= now or "digest" not in previous
                or (previous["digest"] is not None and (
                    not isinstance(previous["digest"], str)
                    or not re.fullmatch(r"[0-9a-f]{64}", previous["digest"])))
                or not isinstance(previous.get("reported"), list)
                or not all(isinstance(key, str) and key for key in previous["reported"])):
            raise ValueError("invalid previous report receipt")

    unseen = sorted(outcomes.keys() - set(previous["reported"]))
    digest = hashlib.sha256(json.dumps(visible, sort_keys=True).encode("utf-8")).hexdigest()
    active = bool(visible["working"] or visible["up_next"])
    due = active and digest != previous["digest"] and now - previous["at"] >= minutes * 60
    if not unseen and not due:
        result = {"due": False, "reason": "waiting" if active else "idle"}
        if needs_baseline:
            result["initialize"] = previous
        return result

    return {
        "due": True,
        "reason": "terminal" if unseen else "scheduled",
        "groups": {"done_since_last_report": [outcomes[key] for key in unseen], **visible},
        "after_delivery": {"at": now, "digest": digest,
                           "reported": sorted(set(previous["reported"]) | set(unseen))},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--now", type=int, default=int(time.time()), help=argparse.SUPPRESS)
    parser.add_argument("--config-only", action="store_true", help="read the Reporting section and print its interval")
    args = parser.parse_args()
    try:
        if args.config_only:
            print(interval(sys.stdin.read()))
            return
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict) or not isinstance(payload.get("config"), str):
            raise ValueError("input must contain the Reporting configuration section")
        print(json.dumps(evaluate(interval(payload["config"]), payload.get("board"),
                                  payload.get("previous"), args.now), separators=(",", ":")))
    except (ValueError, TypeError) as error:
        parser.exit(2, f"pm-report: {error}\n")


if __name__ == "__main__":
    main()
