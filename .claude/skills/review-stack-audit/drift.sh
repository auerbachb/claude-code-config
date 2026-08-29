#!/usr/bin/env bash
# drift.sh — Compare a review-stack snapshot against the recorded baseline.
#
# PURPOSE
#   Answers the one question /review-stack-audit exists to ask: does what each
#   review tool ACTUALLY did this month still match the role we recorded for it?
#   Emits one finding per divergence, each with a stable marker the filing step
#   dedupes on (#1201).
#
#   It is a pure function of two JSON documents. It reaches no network, reads no
#   repo state, and files nothing — so its verdicts are reproducible and its
#   tests need no fixtures beyond the two inputs.
#
# DRIFT TAXONOMY
#   D1 demoted-but-leaned-on   Baseline demoted it (dormant/advisory/off), yet it
#                              was the ONLY tool to find something on >=1 PR. We
#                              are relying on a tool we decided not to rely on.
#   D2 paid-but-unused         Baseline says we pay for it; it did nothing in the
#                              window. That is a bill with no return.
#   D3 cap-shrink              A limit appeared that the baseline did not record.
#                              This is how a silently-shrinking cap surfaces.
#   D4 role-vs-reality         Baseline says it approves via review objects, but
#                              it issued zero APPROVED reviews. The merge gate is
#                              leaning on something absent. Tools that signal a
#                              clean pass through a check-run instead (BugBot) are
#                              exempt — see `approves_via` below.
#   D5 unrecorded-tool         A tool posting findings that the baseline does not
#                              list at all — a new reviewer nobody decided on.
#
#   Every finding carries `severity`: `high` when the merge gate or real money is
#   implicated (D2, D4, and any D3 on a gating tool), `medium` otherwise.
#
# BASELINE FORMAT  (schema "review-stack-baseline/v1")
#   {"schema": "review-stack-baseline/v1",
#    "source": {"issue": 1199, "record": "<path>", "as_of": "YYYY-MM-DD"},
#    "tools": [{"key": "coderabbit",
#               "role": "primary|approver|fallback|advisory|dormant|off",
#               "billed": "paid|free|trial|cancelled|unknown",
#               "gates_merge": true,
#               "approves_via": "review|check_run|none",
#               "expected_caps": ["rate_limit"],
#               "notes": "..."}]}
#
#   `expected_caps` is the load-bearing field for D3: a cap kind already listed
#   is a known cost of doing business, one that is not is news.
#
#   `gates_merge` and `approves_via` are separate on purpose. The first asks
#   "would a cap here stall PRs?" and drives D3's severity; the second asks
#   "should this tool be posting APPROVED review objects?" and is the ONLY
#   trigger for D4. BugBot is why: it can satisfy the merge gate alone, yet
#   signals its clean pass through a check-run and posts no APPROVED review.
#   One combined field would force a false positive on one question or the
#   other. When `approves_via` is absent it falls back to the role.
#
# USAGE
#   drift.sh --snapshot <path> --baseline <path> [--json | --summary]
#   drift.sh --help | -h
#
#   --snapshot  Output of measure.sh (--json form).
#   --baseline  Baseline document, shape above.
#   --json      Full findings document on stdout (DEFAULT).
#   --summary   One `code<TAB>tool<TAB>severity<TAB>headline` line per finding.
#
# OUTPUT (--json)
#   {"generated_at", "window", "baseline_source", "drift_count",
#    "drift": [{"code", "tool", "tool_name", "severity", "headline",
#               "detail", "marker", "observed", "expected"}],
#    "unmatched_baseline_tools": [...], "notes": [...]}
#
# EXIT STATUS
#   0  Analysis complete, NO drift.
#   1  Input unreadable, unparseable, or wrong schema.
#   2  Usage error.
#   3  Analysis complete, drift found. (Matches ci-status.sh's idiom, where 3
#      means "ran fine, and the answer is bad news" — never confused with 1.)
#
# EXAMPLES
#   .claude/skills/review-stack-audit/drift.sh \
#     --snapshot ~/.claude/review-stack-audit/snapshot-2026-08.json \
#     --baseline .claude/reference/review-stack-baseline.json --summary

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "drift.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE="json"
SNAPSHOT=""
BASELINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json)    MODE="json"; shift ;;
    --summary) MODE="summary"; shift ;;
    --snapshot)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--snapshot requires a value"
      SNAPSHOT="$2"; shift 2 ;;
    --snapshot=*)
      SNAPSHOT="${1#--snapshot=}"; [[ -n "$SNAPSHOT" ]] || usage_error "--snapshot value cannot be empty"; shift ;;
    --baseline)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--baseline requires a value"
      BASELINE="$2"; shift 2 ;;
    --baseline=*)
      BASELINE="${1#--baseline=}"; [[ -n "$BASELINE" ]] || usage_error "--baseline value cannot be empty"; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done

[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"
[[ -n "$SNAPSHOT" ]] || usage_error "--snapshot is required"
[[ -n "$BASELINE" ]] || usage_error "--baseline is required"
command -v python3 >/dev/null 2>&1 || { echo "drift.sh: python3 not found" >&2; exit 1; }

DRIFT_MODE="$MODE" DRIFT_SNAPSHOT="$SNAPSHOT" DRIFT_BASELINE="$BASELINE" python3 - <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

mode = os.environ.get("DRIFT_MODE", "json")


def fail(msg):
    print("drift.sh: %s" % msg, file=sys.stderr)
    sys.exit(1)


def load(path, label):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        fail("%s unreadable or unparseable: %s" % (label, exc))


snapshot = load(os.environ["DRIFT_SNAPSHOT"], "snapshot")
baseline = load(os.environ["DRIFT_BASELINE"], "baseline")

if not isinstance(snapshot, dict) or not isinstance(snapshot.get("tools"), list):
    fail("snapshot must be an object with a 'tools' array")
if not isinstance(baseline, dict) or not isinstance(baseline.get("tools"), list):
    fail("baseline must be an object with a 'tools' array")

schema = baseline.get("schema", "")
if schema != "review-stack-baseline/v1":
    # Refuse rather than guess. A baseline whose shape we do not understand
    # would silently produce "no drift" — the one answer this tool must never
    # give without having actually checked.
    fail("baseline schema is %r, expected 'review-stack-baseline/v1'"
         % (schema or "(absent)"))

DEMOTED_ROLES = {"dormant", "advisory", "off"}
VALID_ROLES = {"primary", "approver", "fallback", "advisory", "dormant", "off"}
VALID_BILLED = {"paid", "free", "trial", "cancelled", "unknown"}

base_by_key = {}
notes = []
for entry in baseline["tools"]:
    key = entry.get("key")
    if not key:
        notes.append("Baseline contains a tool with no `key` — skipped.")
        continue
    role = (entry.get("role") or "unknown").lower()
    billed = (entry.get("billed") or "unknown").lower()
    if role not in VALID_ROLES:
        notes.append("Baseline role %r for %s is not a recognized role; "
                     "role-dependent checks (D1, D4) are skipped for it." % (role, key))
    if billed not in VALID_BILLED:
        notes.append("Baseline billed state %r for %s is not recognized; "
                     "D2 is skipped for it." % (billed, key))
    base_by_key[key] = entry

drift = []


def add(code, tool_key, tool_name, severity, headline, detail, observed, expected):
    drift.append({
        "code": code,
        "tool": tool_key,
        "tool_name": tool_name,
        "severity": severity,
        "headline": headline,
        "detail": detail,
        # The marker is the dedup authority downstream. It is keyed on
        # (tool, code) and nothing else, so the SAME unresolved drift re-found
        # next month produces a byte-identical marker and files no duplicate.
        "marker": "<!-- review-stack-audit: %s/%s -->" % (tool_key, code),
        "observed": observed,
        "expected": expected,
    })


# The baseline has a schema guard because a shape we do not understand would
# silently produce "no drift". A snapshot with no tools in it does exactly the
# same thing by a different route: the loop below never runs, `drift` stays
# empty, and the exit code says 0 — "checked everything, found nothing" — when
# nothing was checked at all. Refuse instead.
#
# This is deliberately narrower than "no tool key matches the baseline". A
# snapshot full of tools the baseline has never heard of is not a failed
# comparison; it is five D5 findings, and reporting them is the correct answer.
if not snapshot["tools"]:
    fail("snapshot contains no tools — refusing to report 'no drift' for a "
         "comparison that never happened")

window_truncated = bool(snapshot.get("window", {}).get("truncated"))
d2_suppressed = []
inferred_approves_via = []
seen_keys = set()
for tool in snapshot["tools"]:
    key = tool.get("key")
    if not key:
        continue
    seen_keys.add(key)
    name = tool.get("name") or key
    state = tool.get("observed_state", "unknown")
    sole = int(tool.get("sole_provider_on") or 0)
    approved = int(tool.get("approved") or 0)
    findings = int(tool.get("inline_findings") or 0)
    cap_kinds = list(tool.get("cap_kinds") or [])

    base = base_by_key.get(key)

    # --- D5: a tool nobody decided on -----------------------------------------
    if base is None:
        if findings > 0 or state != "silent":
            add("D5", key, name, "medium",
                "%s is reviewing but is absent from the baseline" % name,
                "It posted %d inline finding(s) across %d PR(s) in the window, "
                "yet the baseline records no role for it. Either it was added "
                "without a decision, or the baseline is missing an entry."
                % (findings, int(tool.get("prs_touched") or 0)),
                {"observed_state": state, "inline_findings": findings},
                {"role": None})
        continue

    role = (base.get("role") or "unknown").lower()
    billed = (base.get("billed") or "unknown").lower()
    gates = bool(base.get("gates_merge"))
    # `gates_merge` and `approves_via` answer different questions and must not be
    # collapsed. "Can a cap here stall PRs?" (gates_merge) is true for BugBot,
    # which alone satisfies the gate on its path; "should this tool be posting
    # APPROVED review objects?" (approves_via) is false for it, because it
    # signals a clean pass through a check-run instead. Driving D4 off
    # gates_merge would fire a permanent false positive on every such tool.
    # Absent field falls back to the role, so a v1 baseline written before this
    # distinction still behaves sanely.
    # Absent field falls back to the role. The fallback deliberately does NOT
    # treat "primary" as approving via review: CodeRabbit is role "primary" and
    # was measured issuing 0 approvals across 63 PRs, so inferring "review"
    # there would fire D4 against it every single run — the permanent false
    # positive this split exists to prevent. A primary that really does approve
    # must say `approves_via: "review"` explicitly.
    #
    # A silently-inferred value can still disable D4 for a tool that should
    # have it, so the inference is reported rather than left invisible.
    if base.get("approves_via"):
        approves_via = base["approves_via"].lower()
    else:
        approves_via = "review" if role == "approver" else "none"
        inferred_approves_via.append((key, role, approves_via))
    expected_caps = set(base.get("expected_caps") or [])

    # --- D1: relying on a tool we decided not to rely on ----------------------
    if role in DEMOTED_ROLES and sole > 0:
        add("D1", key, name, "medium",
            "%s is demoted to '%s' but was the only finder on %d PR(s)" % (name, role, sole),
            "The baseline demoted %s to '%s', which means we accepted losing its "
            "coverage. It was nonetheless the sole source of a finding on %d PR(s) "
            "in this window — coverage we would have lost. Either the demotion is "
            "wrong, or those findings need another tool to catch them."
            % (name, role, sole),
            {"sole_provider_on": sole, "observed_state": state},
            {"role": role})

    # --- D2: paying for silence ----------------------------------------------
    # Only trustworthy on a complete window. When the sample was truncated at
    # measure.sh's --limit, "silent" means "absent from the PRs we happened to
    # look at" — a tool active only in the unsampled remainder looks identical
    # to one that did nothing. Filing a high-severity "cancel this subscription"
    # issue off that is a false positive with real consequences, so D2 is not
    # evaluated here at all. It is not silently skipped: the note below says so.
    if billed == "paid" and state == "silent" and not window_truncated:
        add("D2", key, name, "high",
            "%s is billed as paid but did nothing in the window" % name,
            "The baseline records %s as a paid tool, and it touched zero PRs in "
            "this window. That is a recurring charge returning nothing. Confirm "
            "the subscription is still wanted, or that the tool is still wired up "
            "at all — a paid tool going silent usually means broken wiring, not "
            "a quiet month." % name,
            {"observed_state": "silent", "prs_touched": 0},
            {"billed": "paid"})
    elif billed == "paid" and state == "silent" and window_truncated:
        d2_suppressed.append(key)

    # --- D3: a limit the baseline never recorded ------------------------------
    new_caps = sorted(set(cap_kinds) - expected_caps)
    if new_caps:
        add("D3", key, name, "high" if gates else "medium",
            "%s hit a limit the baseline does not record: %s" % (name, ", ".join(new_caps)),
            "Observed cap kind(s) %s on %d PR(s). The baseline lists %s as expected. "
            "An unrecorded limit is the silent-cap case this audit exists to catch: "
            "throughput drops without anything failing loudly.%s"
            % (", ".join(new_caps),
               len(tool.get("cap_signals") or []),
               ", ".join(sorted(expected_caps)) or "none",
               " This tool gates the merge, so a cap here stalls PRs." if gates else ""),
            {"cap_kinds": cap_kinds, "cap_signals": tool.get("cap_signals") or []},
            {"expected_caps": sorted(expected_caps)})

    # --- D4: the gate is leaning on something absent --------------------------
    if approves_via == "review" and approved == 0:
        add("D4", key, name, "high",
            "%s is the recorded approver but issued zero approvals" % name,
            "The baseline records %s as approving via review objects, yet it "
            "posted no APPROVED review in the window. If the merge gate depends "
            "on that approval, it is depending on something that is not arriving."
            % name,
            {"approved": 0, "observed_state": state},
            {"role": role, "approves_via": approves_via})

# A baseline tool the snapshot never mentions is reported, not silently dropped:
# measure.sh emits a row for every tool it knows, so an absent key means the two
# documents disagree about what the stack even contains.
unmatched = sorted(k for k in base_by_key if k not in seen_keys)
if unmatched:
    notes.append(
        "Baseline lists %d tool(s) the snapshot never measured (%s). No drift is "
        "claimed for them — the snapshot could not speak to them either way."
        % (len(unmatched), ", ".join(unmatched)))

# D4 is the check that catches the merge gate's approver going quiet. A baseline
# entry with no `approves_via` gets one inferred, and for every role but
# "approver" that inference is "none" — which turns D4 off for that tool. Say so,
# rather than letting the check be absent without anyone noticing.
silenced = [k for k, _r, a in inferred_approves_via if a != "review"]
if silenced:
    notes.append(
        "%d baseline entr%s no `approves_via`, so it was inferred from the role "
        "(%s). D4 does not run for tools inferred as anything but \"review\" — set "
        "`approves_via: \"review\"` explicitly on any of these that should be "
        "issuing APPROVED reviews."
        % (len(silenced), "y has" if len(silenced) == 1 else "ies have",
           ", ".join("%s→%s" % (k, a) for k, _r, a in inferred_approves_via)))

if window_truncated:
    notes.append(
        "The snapshot was truncated at its --limit, so throughput and findings "
        "counts are floors and absence of a finding is not proof of absence. "
        "D2 (paid-but-unused) was NOT evaluated on this run: on a partial "
        "window, a tool active only in the unsampled PRs is indistinguishable "
        "from one that did nothing. Re-run with a --limit above the window's PR "
        "count to get a D2 verdict.")
if d2_suppressed:
    notes.append(
        "D2 was suppressed for %d paid tool(s) that looked silent in this "
        "truncated sample (%s). They may be genuinely unused or merely "
        "unsampled — a full window is needed to tell the difference."
        % (len(d2_suppressed), ", ".join(sorted(d2_suppressed))))

if snapshot.get("unclassified"):
    notes.append(
        "The snapshot carries %d unclassified limit-shaped comment(s). If one of "
        "them is a real cap, a D3 finding is missing here — check them before "
        "trusting a clean result." % len(snapshot["unclassified"]))

out = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "window": snapshot.get("window", {}),
    "baseline_source": baseline.get("source", {}),
    "drift_count": len(drift),
    "drift": drift,
    "unmatched_baseline_tools": unmatched,
    "notes": notes,
}

if mode == "summary":
    for d in drift:
        print("%s\t%s\t%s\t%s" % (d["code"], d["tool"], d["severity"], d["headline"]))
else:
    print(json.dumps(out, indent=2, sort_keys=True))

sys.exit(3 if drift else 0)
PY
