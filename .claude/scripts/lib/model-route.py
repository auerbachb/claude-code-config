"""Task-local routing reducer. The caller owns and locks session/handoff state.

The mode/tier table is a recommendation; the launching thread decides (#2449).
A tier marked capable:false is the caller's judgment that it does not suit the
task and is honoured: with a valid capability_gap (kind tool|context|permissions,
nonblank detail and evidence) it goes in capability_gaps, without one it is a
recorded note in capability_fallback. Only an owner pin keeps a judged tier.
An optional parent_choice {model, reason} launches on another model, lower or
higher, with a one-line reason; the decision records recommended_model, the
chosen model and the reason. Owner pins win; Fable stays owner-only outside speed.

The optional run mode (default|speed|cheap; absent or unknown reads as default)
picks the starting tier for an issue tier (Light|Standard|Heavy; an unresolved tier
routes as Standard and the reason says so). Mode also sets escalation patience: speed moves up
after one failed attempt without new evidence, default and cheap need diagnosis.
"""
import argparse
import json
import math
import re
import sys
from pathlib import Path


ORDER = ("haiku", "sonnet", "opus")
MODELS = ORDER + ("fable",)
GAP_KINDS = ("tool", "context", "permissions")
MODES = ("default", "speed", "cheap")
TIERS = ("Light", "Standard", "Heavy")
# Start preference per mode and issue tier; the first eligible entry wins.
# Fable is never a starting tier. It is reached only as the speed-mode escalation
# step above an Opus worker (see successor_for), and only by an explicit owner pin.
START_LADDER = {
    "default": {"Light": ("haiku", "sonnet", "opus"), "Standard": ("sonnet", "haiku", "opus"),
                "Heavy": ("opus", "sonnet", "haiku")},
    "speed": {"Light": ("sonnet", "opus", "haiku"), "Standard": ("opus", "sonnet", "haiku"),
              "Heavy": ("opus", "sonnet", "haiku")},
    "cheap": {tier: ("haiku", "sonnet", "opus") for tier in TIERS},
}


def text(value):
    return isinstance(value, str) and bool(value.strip())


def valid_gap(gap):
    return (isinstance(gap, dict) and gap.get("kind") in GAP_KINDS
            and text(gap.get("detail")) and text(gap.get("evidence")))


def number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def pointers(value):
    return isinstance(value, list) and all(text(item) for item in value)


def require(ok, message):
    if not ok:
        raise ValueError(message)


LAUNCH_ACTIONS = ("start", "retry", "escalate")


def parse_choice(choice):
    # The launching thread's own pick: any known model plus a one-line reason.
    if choice is None:
        return None
    require(isinstance(choice, dict) and choice.get("model") in MODELS,
            "parent_choice must be an object naming a known model")
    reason = choice.get("reason")
    # Any line separator in the original text is refused, leading or trailing ones included.
    require(text(reason) and reason.splitlines() == [reason] and len(reason) <= 500,
            "parent_choice.reason is required: one line saying why this model departs from the recommendation")
    return {"by": "parent", "model": choice["model"], "reason": reason.strip(), "applied": False}


def decide(request):
    require(isinstance(request, dict), "request must be an object")
    choice = parse_choice(request.get("parent_choice"))
    require(all(isinstance(request.get(k), str) and re.fullmatch(r"[A-Za-z0-9_.:/@+-]{1,512}", request[k])
                for k in ("task", "phase")), "task and phase must be stable metadata identifiers")
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
        require(attempt.get("outcome") in ("failed", "progress", "complete", "waiting", "exhaustion"), "invalid outcome")
        if attempt["outcome"] == "failed":
            require(all(text(attempt.get(k)) for k in ("bug", "signature", "approach")),
                    "failed attempts require bug, failure signature and approach")
        require(pointers(attempt.get("evidence")) and attempt["evidence"], "attempt evidence required")
        require(pointers(attempt.get("new_evidence", [])), "new_evidence must be an array")
        require(attempt["outcome"] != "progress" or bool(attempt.get("new_evidence")),
                "progress requires new evidence pointers")
        if attempt["outcome"] != "complete":
            require(text(attempt.get("remaining_blocker")) or text(attempt.get("next_action")),
                    "remaining blocker or next action required")
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
    fallbacks, gaps = [], []
    mode = request.get("mode")
    mode = mode if mode in MODES else "default"
    # An unresolved tier (absent or null: unestimated, or the estimate helper failed) routes as
    # Standard and the decision says so. A supplied but unrecognized tier is invalid.
    tier_unresolved = request.get("tier") is None
    tier = "Standard" if tier_unresolved else request.get("tier")
    require(tier in TIERS, "tier must be Light, Standard or Heavy")
    result = {
        "schema_version": 1, "task": request["task"], "phase": request["phase"],
        "mode": mode, "tier": tier,
        "action": "blocked", "model": None, "recommended_model": None, "choice": choice, "reason": "",
        "capability_fallback": [], "capability_gaps": [],
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

    def finish(action, reason, model=None, recommended="same"):
        for notes in (fallbacks, gaps):
            unique = []
            for note in notes:
                if note not in unique:
                    unique.append(note)
            notes[:] = unique
        # Every judged tier is named: skipped on the caller's judgment, or kept by an owner pin.
        clauses = [(" Owner pin kept %s despite capable:false (basis %s)." if note["model"] == model
                    else " %s skipped on caller judgment (capable:false, basis %s).")
                   % (note["model"], note["basis"]) for note in fallbacks]
        # A gap on a tier the router moved past is "skipped"; on a blocked
        # decision (e.g. an owner pin) that tier was held, not passed over.
        verb = "blocked by" if action == "blocked" else "skipped for"
        clauses += [" %s %s accepted %s capability gap." % (note["model"], verb, note["kind"])
                    for note in gaps]
        if choice is not None and owner is not None:
            # An owner pin wins over a parent choice, which stays recorded as not applied.
            clauses.append(" Owner pin wins over the parent choice of %s." % choice["model"])
        if tier_unresolved:
            reason = "Tier unresolved; routed as Standard. " + reason
        if recommended == "same":
            recommended = model if action in LAUNCH_ACTIONS else None
        result.update(action=action, reason=reason + "".join(clauses), model=model,
                      recommended_model=recommended,
                      capability_fallback=list(fallbacks), capability_gaps=list(gaps))
        if action in ("blocked", "diagnose", "owner_decision", "wait"):
            result["submission_allowed"] = False
        return result

    def assess(model, pinned=False):
        # Records a note only for a row the active branch examined.
        row = inventory.get(model, {})
        if not (all(row.get(k) is True for k in ("available", "budget_allowed", "reserve_allowed"))
                and text(row.get("evidence"))):
            return False
        capable = row.get("capable")
        if capable is True:
            return True
        if capable is not False:
            return False
        gap = row.get("capability_gap")
        if valid_gap(gap):
            gaps.append({"model": model, "kind": gap["kind"], "detail": gap["detail"],
                         "evidence": gap["evidence"]})
            return False
        # No gap is needed: the caller's judgment that the tier is unsuitable is honoured
        # and recorded as a note. Only an owner pin keeps the judged tier.
        fallbacks.append({"model": model, "basis": "missing" if gap is None else "malformed"})
        return pinned

    def next_tier(model):
        # The next eligible cost-ladder tier above model.
        start = ORDER.index(model) + 1 if model in ORDER else len(ORDER)
        for candidate in ORDER[start:]:
            if assess(candidate):
                return candidate
        return None

    def successor_for(model):
        # Speed mode's top step: an Opus worker that must move up escalates to fable when it is
        # eligible. Default and cheap never reach fable without an explicit owner choice.
        if mode == "speed" and model == "opus" and assess("fable"):
            return "fable"
        return next_tier(model)

    if attempts and attempts[-1]["outcome"] == "complete":
        return finish("complete", "Task finished; verify its independent acceptance and merge gates.")
    if request.get("launch_allowed") is not True or request.get("permissions_preserved") is not True:
        return finish("blocked", "Launch controls or unchanged permission/tool boundaries are not explicitly clear.")
    if current == "fable" and owner is None and mode != "speed" and (choice is None or choice["model"] == "fable"):
        # An eligible parent choice away from an unpinned Fable worker is applied below.
        return finish("blocked", "Retain the explicit owner choice for a tier outside the unattended ladder.")
    runtime = request.get("runtime", {})
    version = runtime.get("version") if isinstance(runtime, dict) else None
    parsed = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version) if isinstance(version, str) else None
    if parsed is None or tuple(map(int, parsed.groups())) < (2, 1, 251):
        return finish("blocked", "Verify Claude Code >=2.1.251 so explicit models override legacy defaults.")
    if runtime.get("model_override_forced") is not False:
        return finish("blocked", "A forced/unknown runtime model override cannot honor the routed model; preserve owner control.")
    if choice is not None and owner is None:
        # The launching thread decides; the recommendation is what the table alone would do.
        if attempts and attempts[-1]["outcome"] == "waiting":
            wake = request.get("wake_evidence", [])
            require(pointers(wake), "wake_evidence must be pointers to changed state")
            if not wake:
                # An unchanged wait holds whatever the current model's eligibility.
                return finish("wait", "Keep existing monitoring; unchanged waiting is not a failure or a new "
                              "model invocation. Parent choice not applied: nothing to launch.")
        baseline = decide(dict(request, parent_choice=None))
        if baseline["action"] in ("complete", "wait"):
            baseline["choice"] = choice
            baseline["reason"] += " Parent choice not applied: nothing to launch."
            return baseline
        recommended = baseline["model"] if baseline["action"] in LAUNCH_ACTIONS else None
        # Keep the baseline's exclusion evidence in the persisted decision.
        fallbacks.extend(baseline["capability_fallback"])
        gaps.extend(baseline["capability_gaps"])
        chosen = choice["model"]
        if chosen == "fable" and mode != "speed":
            return finish("blocked", "Fable needs an explicit owner choice outside speed mode; parent choice not applied.",
                          recommended=recommended)
        if not assess(chosen):
            return finish("blocked", "Parent-chosen %s is unavailable/ineligible; never substitute silently." % chosen,
                          recommended=recommended)
        choice["applied"] = True
        action = "start" if not attempts else ("retry" if chosen == current else "escalate")
        return finish(action, "Parent choice %s (recommended %s; router action %s): %s." % (
            chosen, recommended or "none", baseline["action"], choice["reason"].rstrip(".")), chosen, recommended=recommended)
    judged = False
    if owner is not None:
        if not assess(owner, pinned=True):
            return finish("blocked", "Owner-selected model is unavailable/ineligible; never substitute silently.")
        selected = owner
    elif current is not None:
        if not assess(current):
            if not (fallbacks and fallbacks[-1]["model"] == current):
                return finish("blocked", "Current model is unavailable/ineligible; refresh inventory and reserve/budget gates.")
            judged = True  # capable:false on the current tier: the caller judged it unsuitable
        selected = current
    else:
        selected = None
        preferred = START_LADDER[mode][tier]
        for candidate in preferred:
            if assess(candidate):
                selected = candidate
                break
        if selected is None:
            return finish("blocked", "No explicitly available capable model within budget/reserve controls.")
    if not attempts:
        if owner:
            return finish("start", "Owner choice preserved.", selected)
        reason = "%s mode, %s work: start on %s." % (mode, tier, selected)
        if selected != preferred[0]:
            reason = ("%s mode, %s work: preferred %s unavailable or ineligible; started on %s instead."
                      % (mode, tier, preferred[0], selected))
        return finish("start", reason, selected)
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
    if latest["outcome"] == "waiting":
        wake = request.get("wake_evidence", [])
        require(pointers(wake), "wake_evidence must be pointers to changed state")
        if not wake:
            return finish("wait", "Keep existing monitoring; unchanged waiting is not a failure or a new model invocation.")
        if not judged:
            return finish("retry", "New state evidence wakes the same task/model.", selected)
    if judged:
        successor = successor_for(current)
        if successor is None:
            return finish("blocked", "Caller judged %s unsuitable and no eligible tier is above it." % current)
        return finish("escalate", "Caller judged %s unsuitable; fresh context on %s for this task/phase only."
                      % (current, successor), successor)
    if latest["outcome"] == "exhaustion":
        return finish("retry", "Resume from the valid recovery handoff on the same model; exhaustion is not poor quality.", selected)
    if latest["outcome"] == "progress" or latest.get("new_evidence", []):
        return finish("retry", "Useful progress: retain discoveries and targeted feedback on the same model.", selected)
    if mode == "speed" and owner is None and latest["outcome"] == "failed":
        # Speed trades diagnosis patience for time: one failure without new evidence moves up.
        successor = successor_for(current)
        if successor is not None:
            return finish("escalate", "Speed mode: one failed attempt without new evidence moves up to %s; "
                          "fresh context for this task/phase only." % successor, successor)
    repeated =(len(window) >= 2 and all(a["outcome"] == "failed" and not a.get("new_evidence", []) for a in window[-2:])
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
                 and diagnosis.get("approaches_verified") is True
                 and all(text(a.get("method_evidence"))
                         and isinstance(a.get("method_fingerprint"), str)
                         and re.fullmatch(r"[0-9a-f]{64}", a["method_fingerprint"]) for a in cited)
                 and len({a.get("method_fingerprint") for a in cited}) >= 2
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
    successor = successor_for(current)
    if successor is None:
        return finish("blocked", "No eligible next tier; retain recovery evidence without bypassing budgets or permissions.")
    return finish("escalate", "Diagnosed " + kind + "; fresh context for this task/phase only.", successor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    args = parser.parse_args()
    try:
        require(args.input.stat().st_size <= 1024 * 1024, "request exceeds 1 MiB; use evidence pointers")
        result = decide(json.loads(args.input.read_text(encoding="utf-8")))
        print(json.dumps(result, allow_nan=False))
        return 3 if result["action"] in ("blocked", "diagnose", "owner_decision", "wait") else 0
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print(json.dumps({"action": "invalid", "model": None, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
