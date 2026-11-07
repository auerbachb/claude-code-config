"""Task-local routing reducer. The caller owns and locks session/handoff state."""
import argparse
import json
import math
import sys
from pathlib import Path


ORDER = ("haiku", "sonnet", "opus")
MODELS = ORDER + ("fable",)


def text(value):
    return isinstance(value, str) and bool(value.strip())


def number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value >= 0)


def pointers(value):
    return isinstance(value, list) and all(text(item) for item in value)


def require(ok, message):
    if not ok:
        raise ValueError(message)


def decide(request):
    require(isinstance(request, dict), "request must be an object")
    require(text(request.get("task")) and text(request.get("phase")), "task and phase required")
    models = request.get("models")
    require(isinstance(models, list), "models must be an explicit runtime inventory")
    inventory = {}
    for row in models:
        require(isinstance(row, dict) and row.get("model") in MODELS, "unknown model alias")
        require(row["model"] not in inventory, "duplicate model")
        inventory[row["model"]] = row
    attempts = request.get("attempts", [])
    require(isinstance(attempts, list), "attempts must be an array")
    ids = set()
    for attempt in attempts:
        require(isinstance(attempt, dict), "attempt must be an object")
        require(text(attempt.get("id")) and attempt["id"] not in ids, "unique attempt id required")
        ids.add(attempt["id"])
        require(attempt.get("model") in MODELS, "attempt model required")
        require(attempt.get("outcome") in ("failed", "progress", "complete"), "invalid outcome")
        require(all(text(attempt.get(k)) for k in ("bug", "signature", "approach")),
                "bug, failure signature and approach required")
        require(pointers(attempt.get("evidence")) and attempt["evidence"], "attempt evidence required")
        require(pointers(attempt.get("new_evidence")), "new_evidence must be an array")
        require(attempt["outcome"] != "progress" or bool(attempt["new_evidence"]),
                "progress requires new evidence pointers")
        if attempt["outcome"] != "complete":
            require(text(attempt.get("remaining_blocker")), "remaining blocker required")
        for key in ("review_rounds", "ci_reruns"):
            value = attempt.get(key, 0)
            require(isinstance(value, int) and not isinstance(value, bool) and value >= 0,
                    key + " must be a nonnegative integer, per attempt, not cumulative")
        for key in ("cost_usd", "elapsed_seconds"):
            require(attempt.get(key) is None or number(attempt[key]), key + " must be null or nonnegative")
    current = request.get("current_model")
    owner = request.get("owner_model")
    require(current is None or current in MODELS, "invalid current model")
    require(owner is None or owner in MODELS, "invalid owner model")
    require(not attempts or current is not None, "attempt history requires current_model")
    require(not attempts or attempts[-1]["model"] == current, "latest attempt must match current_model")
    require(attempts or current is None or current == owner,
            "current_model without attempt history is not evidence for a premium default")
    submission = request.get("submission", {})
    require(isinstance(submission, dict), "submission must be an object")
    known_costs = [a["cost_usd"] for a in attempts if a.get("cost_usd") is not None]
    known_times = [a["elapsed_seconds"] for a in attempts if a.get("elapsed_seconds") is not None]
    result = {
        "schema_version": 1, "task": request["task"], "phase": request["phase"],
        "action": "blocked", "model": None, "reason": "",
        "attempt_ids": [a["id"] for a in attempts],
        "submission_allowed": all(submission.get(k) is True for k in
                                  ("local_checks_passed", "distinct_changes", "batched")),
        "metrics": {
            "attempts": len(attempts), "completed": bool(attempts and attempts[-1]["outcome"] == "complete"),
            "failed_attempts": sum(a["outcome"] == "failed" for a in attempts),
            "review_rounds": sum(a.get("review_rounds", 0) for a in attempts),
            "ci_reruns": sum(a.get("ci_reruns", 0) for a in attempts),
            "known_cost_usd": sum(known_costs) if known_costs else None,
            "total_cost_usd": sum(known_costs) if len(known_costs) == len(attempts) and attempts else None,
            "total_elapsed_seconds": sum(known_times) if len(known_times) == len(attempts) and attempts else None,
        },
    }

    def finish(action, reason, model=None):
        result.update(action=action, reason=reason, model=model)
        if action in ("blocked", "diagnose", "owner_decision"):
            result["submission_allowed"] = False
        return result

    def eligible(model):
        row = inventory.get(model, {})
        return (all(row.get(k) is True for k in
                    ("available", "capable", "budget_allowed", "reserve_allowed"))
                and text(row.get("evidence")))

    if attempts and attempts[-1]["outcome"] == "complete":
        return finish("complete", "Task finished; verify its independent acceptance and merge gates.")
    if request.get("launch_allowed") is not True or request.get("permissions_preserved") is not True:
        return finish("blocked", "Launch controls or unchanged permission/tool boundaries are not explicitly clear.")
    if current == "fable" and owner is None:
        return finish("blocked", "Retain the explicit owner choice for a tier outside the unattended ladder.")
    if owner is not None:
        if not eligible(owner):
            return finish("blocked", "Owner-selected model is unavailable/ineligible; never substitute silently.")
        selected = owner
    elif current is not None:
        if not eligible(current):
            return finish("blocked", "Current model is unavailable/ineligible; refresh inventory and reserve/budget gates.")
        selected = current
    else:
        selected = next((m for m in ORDER if eligible(m)), None)
        if selected is None:
            return finish("blocked", "No explicitly available capable model within budget/reserve controls.")
    if not attempts:
        return finish("start", "Owner choice preserved." if owner else "Cheapest eligible configured tier.", selected)
    if owner and owner != current:
        return finish("start", "New explicit owner choice; launch a fresh context with prior discoveries.", owner)
    # A fresh tier begins its own evidence window. Earlier cheap-tier failures
    # must not immediately escalate the replacement worker again.
    window = []
    for attempt in reversed(attempts):
        if attempt["model"] != current:
            break
        window.append(attempt)
    window.reverse()
    latest = window[-1]
    if latest["outcome"] == "progress" or latest["new_evidence"]:
        return finish("retry", "Useful progress: retain discoveries and targeted feedback on the same model.", selected)
    repeated = (len(window) >= 2 and all(a["outcome"] == "failed" and not a["new_evidence"] for a in window[-2:])
                and window[-2]["bug"] == latest["bug"] and window[-2]["signature"] == latest["signature"])
    poor = [a for a in window if a.get("poor_patch") is True and a["outcome"] == "failed"
            and a.get("review_rounds", 0) + a.get("ci_reruns", 0) > 0]
    churn = len(poor) >= 2
    if not repeated and not churn:
        return finish("retry", "A single failure, slow work or attempt count is not escalation evidence.", selected)
    diagnosis = request.get("diagnosis")
    if not isinstance(diagnosis, dict):
        return finish("diagnose", "Repeated equivalent failures or poor-patch churn: diagnose before upgrading.", selected)
    cited_ids = diagnosis.get("attempt_ids", [])
    require(pointers(cited_ids) and len(cited_ids) == len(set(cited_ids)), "unique diagnosis attempt_ids required")
    cited = [a for a in window if a["id"] in cited_ids]
    require(len(cited) == len(cited_ids), "diagnosis may cite only current-tier attempts")
    kind = diagnosis.get("kind")
    supported = (kind == "stuck_bug" and repeated and len(cited) >= 2
                 and len({a["approach"] for a in cited}) >= 2
                 and all(a["outcome"] == "failed" and a["bug"] == latest["bug"] for a in cited))
    supported = supported or (kind == "poor_patch_churn" and churn and len(cited) >= 2
                              and all(a in poor for a in cited))
    supported = (supported and diagnosis.get("model") == current
                 and text(diagnosis.get("why_more_retries_unlikely"))
                 and pointers(diagnosis.get("evidence")) and bool(diagnosis["evidence"]))
    if not supported:
        return finish("diagnose", "Diagnosis lacks meaningful current-task attempts, evidence or rationale.", selected)
    if owner is not None:
        return finish("owner_decision", "Evidence supports escalation but an explicit owner model is pinned.", selected)
    start = ORDER.index(current) + 1 if current in ORDER else len(ORDER)
    successor = next((m for m in ORDER[start:] if eligible(m)), None)
    if successor is None:
        return finish("blocked", "No eligible next tier; retain recovery evidence without bypassing budgets or permissions.")
    return finish("escalate", "Diagnosed " + kind + "; fresh context for this task/phase only.", successor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    args = parser.parse_args()
    try:
        require(args.input.stat().st_size <= 1024 * 1024, "request exceeds 1 MiB; use evidence pointers")
        result = decide(json.loads(args.input.read_text()))
        print(json.dumps(result, allow_nan=False))
        return 3 if result["action"] in ("blocked", "diagnose", "owner_decision") else 0
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print(json.dumps({"action": "invalid", "model": None, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
