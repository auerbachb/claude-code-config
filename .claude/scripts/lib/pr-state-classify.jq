# Comment classification used by pr-state.sh --since and poll-watermarks.sh.
# The normal null-input mode builds pr-state's timestamp-filtered bundle from
# the four jq bindings below. Array input is the internal helper mode: classify
# each supplied item without filtering its author or timestamp, so watermark
# polling can apply its own five-bot/ID scope without copying these rules.
#
# Classification rules are documented in fixpr/SKILL.md Step 5b and must stay
# in sync with the regex branches below.
#
# Branch ordering in classify is deliberate — do NOT reorder without reading this:
#   1. Explicit-resolution / clean-pass overrides (addressed marker, withdrawn marker, "actionable comments posted: 0",
#      "no actionable comments were generated"; CR rate-limit notices — "rate limit exceeded" /
#      "rate[- ]limited by coderabbit" / "currently rate limited" / "review limit reached" /
#      "next <=2 words> review (will be) available in"; BugBot usage-limit notices — "couldn't run - usage limit
#      reached" / "this run hit a usage or spend limit"; "full review triggered", BugBot clean-pass
#      "found no new issues", BugBot BUGBOT_REVIEW zero-issue summary, CR error stub
#      "Oops, something went wrong"; CR auto-reply ack marker
#      "<!-- This is an auto-generated reply by CodeRabbit -->")
#      are checked FIRST. They mean CR/BugBot has issued a clean pass, reported a rate/usage limit
#      instead of reviewing, posted a review-started ack, or emitted a transient error — regardless
#      of any quoted earlier finding language. CR wraps its Fair-Usage notice in a "Full review
#      finished" ack, so the "full review triggered" branch does NOT cover it — the rate-limit
#      phrases must.
#      Every CR rate-limit phrase names CR's own notice wording. A bare "fair usage limits policy"
#      was tried and rejected (#557): it is generic enough that a real finding *quoting* the policy
#      would classify as an ack. Each observed CR variant is caught by >=2 of the phrases above,
#      so no single generic phrase has to carry it.
#      The "next … available in" phrase carries a BOUNDED 0-2 inserted-word allowance (issue #1364):
#      CodeRabbit reworded it to "Next included review available in N minutes." and the fixed phrase
#      stopped matching. Redundancy is what saved this branch — the marker alternative still matched
#      the same bodies — but the same drift zeroed escalate-review.sh's window parser, which had no
#      second phrase to fall back on. Both are now keyed on the same stable anchors; keep them so.
#      The withdrawn marker (#611) is safe in this tier-1 group even though the walkthrough marker
#      (override #6 below) is deliberately not: a withdrawal retracts the single finding in its own
#      thread — there is no *other* active finding for an early override to mask — so hoisting it
#      here cannot produce a false clean. Marker-only, mirroring the addressed marker: the prose
#      "Withdrawing the finding" is NOT matched, avoiding the #557 generic-phrase false-ack risk.
#      The CR auto-reply ack marker (#669) is likewise safe in tier 1: CR posts it only on its own
#      reply-ack comments ("Received — CodeRabbit is reviewing…"), which never carry their own
#      findings. Keyed on the HTML marker, not the prose "Received — CodeRabbit is reviewing",
#      so a real finding quoting that phrase cannot be falsely reclassified (#557 discipline).
#      Case-insensitive "i" flag, consistent with CR-authored boilerplate (subject to casing drift).
#      The CodeAnt review-status marker (#1207) is also safe in tier 1: CodeAnt posts it only on its
#      status-table comments (e.g. "✅ Reviewed your PR | …") via the machine-readable HTML comment
#      <!-- codeant-review-status:[…] -->. This marker never appears in a real finding body.
#      Keyed on the HTML comment prefix only — case-sensitive, no "i" flag, because the marker is
#      machine-generated JSON and casing is stable.
#   2. The specific "actionable comments posted: 0" and "no actionable comments were
#      generated" checks MUST precede the general "actionable comments posted" finding
#      check — otherwise the general pattern swallows clean CR summaries as findings.
#   3. BugBot BUGBOT_REVIEW zero-issue check MUST precede the generic "issues? found"
#      finding pattern — otherwise the finding pattern swallows BugBot clean summaries.
#   4. Finding patterns (severity/badges/phrases/suggestions) come next.
#   5. Weak-ack fallback (lgtm variants) next, so it can't hide a real finding.
#   6. Greptile clean-pass summary ("Greptile Summary" heading, placed after severity
#      checks but before the generic "issues? found" finding phrase — #743) sits with the
#      CR walkthrough/summary marker as the LAST overrides, immediately above the default
#      — deliberately NOT in the tier-1 group above (#575, #743).
#      This is a different trigger from #557's rate-limit/usage-limit family: the walkthrough is
#      the boilerplate CR posts on nearly every PR, and it matched no branch at all, so it fell
#      through to default → finding and produced phantom findings.
#      Its late placement is load-bearing: the walkthrough can carry "actionable comments posted: N"
#      (N > 0) and severity keywords for the findings it is summarizing. Hoisting this branch up
#      with the other overrides would mask those real findings — a false clean on the review gate,
#      which is strictly worse than the phantom-finding noise it fixes. Every finding pattern must
#      be evaluated first and win. Ordering alone supplies that guard, so no AND-not guard (of the
#      BugBot zero-issue kind) is needed here.
#      Greptile's issue-comment summary (#743) follows the same late-placement rule for the
#      walkthrough half of this tier; the Greptile branch itself sits just above the generic
#      "issues? found" phrase because clean summaries say "no issues found" — caught by that
#      phrase if the Greptile branch were any later. The branch requires the summary heading
#      and either no "issues found" prose or the explicit "no issues found" clean-pass wording,
#      so a summary that reports N>0 issues still reaches the finding phrase below.
#   7. Default is finding — under-classifying is the failure mode this skill prevents.

def classify:
  if . == null or . == "" then {class: "acknowledgment", reason: "empty body"}
  elif test("<!--\\s*<review_comment_addressed>\\s*-->"; "") then {class: "acknowledgment", reason: "addressed marker"}
  elif test("<!--\\s*<review_comment_withdrawn>\\s*-->"; "") then {class: "acknowledgment", reason: "withdrawn marker"}
  elif test("actionable comments posted:\\s*0\\b"; "i") then {class: "acknowledgment", reason: "CR reports zero actionable"}
  elif test("no actionable comments were generated"; "i") then {class: "acknowledgment", reason: "CR no actionable comments generated"}
  elif test("rate limit exceeded|rate.limited by coderabbit|currently rate limited|review limit reached|\\bnext(?:\\s+\\w+){0,2}\\s+review (will be )?available in"; "i") then {class: "acknowledgment", reason: "rate limit notice"}
  elif test("couldn['’]t run\\s*[-–—]\\s*usage limit reached|this run hit a usage or spend limit"; "i") then {class: "acknowledgment", reason: "BugBot usage limit notice"}
  elif test("full review triggered"; "i") then {class: "acknowledgment", reason: "review-started ack"}
  elif test("found no new issues"; "i") then {class: "acknowledgment", reason: "BugBot clean pass"}
  elif (test("<!--\\s*BUGBOT_REVIEW\\s*-->"; "") and (test("found [1-9][0-9]* potential issue"; "i") | not)) then {class: "acknowledgment", reason: "BugBot zero-issue summary"}
  elif test("Oops, something went wrong"; "i") then {class: "acknowledgment", reason: "CR error stub / transient noise"}
  elif test("<!--\\s*This is an auto-generated reply by CodeRabbit\\s*-->"; "i") then {class: "acknowledgment", reason: "CR auto-reply ack"}
  elif test("<!--\\s*codeant-review-status:"; "") then {class: "acknowledgment", reason: "CodeAnt review-status table"}
  elif test("\\b(critical|major|minor|nitpick|p[0-2])\\b"; "i") then {class: "finding", reason: "severity keyword"}
  elif test("🔴|🟠|🟡"; "") then {class: "finding", reason: "severity badge"}
  elif test("actionable comments posted"; "i") then {class: "finding", reason: "actionable phrase"}
  elif (test("Greptile Summary"; "i") and ((test("issues? found"; "i") | not) or test("no issues found"; "i"))) then {class: "acknowledgment", reason: "Greptile clean-pass summary"}
  elif test("potential[_ ]issue|issues? found|findings?:"; "i") then {class: "finding", reason: "finding phrase"}
  elif test("Prompt for AI Agent"; "i") then {class: "finding", reason: "CR fix prompt"}
  elif test("```suggestion"; "m") then {class: "finding", reason: "suggestion block"}
  elif test("\\b(lgtm|looks good|approved|confirmed|resolved)\\b"; "i") then {class: "acknowledgment", reason: "lgtm variant"}
  elif test("<!--\\s*This is an auto-generated comment:\\s*summarize by coderabbit\\.ai\\s*-->"; "i") then {class: "acknowledgment", reason: "CR walkthrough summary"}
  else {class: "finding", reason: "default — no pattern matched"}
  end;

def enrich($since; $tsfield):
  [.[]
   | select((.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]" or .user.login == "cursor[bot]")
            and ((.[$tsfield] // "") > $since))
   | {
       id,
       user: .user.login,
       ts: .[$tsfield],
       url: (.html_url // .url),
       body,
       classification: (.body | classify)
     }];

if type == "array" then
  [.[] | . + {classification: ((.body // null) | classify)}]
else
  {
    reviews: ($reviews | enrich($since; "submitted_at")),
    inline: ($inline | enrich($since; "created_at")),
    conversation: ($conversation | enrich($since; "created_at"))
  }
  | . + {
      finding_count: ([.reviews[], .inline[], .conversation[]] | map(select(.classification.class == "finding")) | length),
      acknowledgment_count: ([.reviews[], .inline[], .conversation[]] | map(select(.classification.class == "acknowledgment")) | length)
    }
end
