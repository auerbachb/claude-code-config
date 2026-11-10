#!/usr/bin/env bash
# desk/hooks/question-leak-warn.sh — the prose-question nudge (issue #1778): a
# Stop hook that warns, once per turn, when the final assistant message asks
# the operator a question in prose instead of through the question tool.
#
# Registered as .claude/hooks/question-leak-warn.sh, a symlink to this file
# (global-settings.json, Stop). The worker contract it backs up is
# .claude/rules/human-queue.md: ask only through AskUserQuestion, print the
# capture hook's receipt (`question D-<n> sent to human queue`), then proceed
# on the default or park. A question written as prose never reaches the
# capture hook, so no desk sees it (desk/DESIGN.md 2.4).
#
# Detection, on the final assistant message only:
#   - a QUESTION line ends in `?` once trailing whitespace and `*`, `_`, `~`
#     emphasis are stripped, and sits outside fenced code blocks (``` or ~~~,
#     on a line of their own or opening a list item);
#   - never a question: headings (#), blockquotes (>), table rows (|) — also
#     nested in a list item (`- > quoted?`) — a `?` inside inline code, a
#     bare URL (a list marker at most), a line with no words. Quoted or bracketed questions (`?"`, `?)`) and questions answered
#     on the same line do not end in `?`, so they never match;
#   - a RECEIPT line names `question D-<n>` or `questions D-<n>, D-<m>`
#     followed by `sent to human queue` (any case, anywhere in the line),
#     outside fenced code blocks and blockquotes (there it is an example);
#   - warn when some question line has no receipt line after it, quoting the
#     first such line.
#
# Output: one hookSpecificOutput.additionalContext object (the
# dirty-main-warn.sh convention), never decision: block. Stop context
# continues the conversation for one more model request, and every later Stop
# of that turn arrives with stop_hook_active: true. So the hook warns at most
# once per turn: a warning leaves a marker directory,
# $TMPDIR/claude-question-leak-warn-<session_id>, which the turn's first Stop
# (stop_hook_active false) removes. With stop_hook_active true it warns only
# when it can create that marker first — a turn another Stop hook continued
# is still checked, and a turn it already warned in (or one it cannot record)
# is not, so it can never loop.
#
# Input: last_assistant_message when the payload carries it as a string (even
# empty); only when it does not, the last assistant message in
# transcript_path (its final 2 MiB, malformed lines skipped).
#
# Fails open: no jq, bad JSON, an unreadable transcript, any error — nothing
# on stdout or stderr. Always exits 0. Needs no database.
#
# QUESTION_LEAK_WARN_JQ overrides the jq binary (tests only).
#
# Bash 3.2 compatible (macOS /bin/bash).

# The receipt the capture hook's denial names, singular or plural, matched
# against the lowercased line. Change it here if the receipt wording changes.
QLW_RECEIPT_RE='questions? d-[0-9]+(, *d-[0-9]+)* sent to human queue'
# Longest stretch of the leaked line quoted back in the warning.
QLW_QUOTE_MAX=120
# How much of the transcript tail the fallback reads.
QLW_TAIL_BYTES=2097152

qlw_payload=$(cat 2>/dev/null) || exit 0
[ -n "$qlw_payload" ] || exit 0

# Find jq: the app may start hooks with a minimal PATH.
if [ -n "${QUESTION_LEAK_WARN_JQ+x}" ]; then
  qlw_jq="$QUESTION_LEAK_WARN_JQ"
else
  qlw_jq=$(command -v jq 2>/dev/null) || qlw_jq=""
  if [ -z "$qlw_jq" ]; then
    for qlw_c in /opt/homebrew/bin/jq /usr/local/bin/jq; do
      if [ -x "$qlw_c" ]; then qlw_jq="$qlw_c"; break; fi
    done
  fi
fi
if [ -z "$qlw_jq" ] || [ ! -x "$qlw_jq" ]; then exit 0; fi

# One jq call reads `<source>|<stop_hook_active>|<session id>`. The source is
# skip when there is nothing to scan; most turns end there (no `?` at all).
qlw_head=$(printf '%s' "$qlw_payload" | "$qlw_jq" -r '
  if type != "object" then "skip|0|" else
    [ (if (.last_assistant_message | type) == "string" then
         (if (.last_assistant_message | index("?")) != null then "message" else "skip" end)
       elif (.transcript_path | type) == "string" and .transcript_path != "" then "transcript"
       else "skip" end),
      (if .stop_hook_active == true then "1" else "0" end),
      ((.session_id // "") | tostring | gsub("[^A-Za-z0-9_-]"; "") | .[0:128])
    ] | join("|")
  end' 2>/dev/null) || exit 0
qlw_mode=${qlw_head%%|*}
qlw_rest=${qlw_head#*|}
qlw_active=${qlw_rest%%|*}
qlw_sid=${qlw_rest#*|}

# The once-per-turn marker (see the header).
qlw_marker=""
if [ -n "$qlw_sid" ]; then
  qlw_marker="${TMPDIR:-/tmp}"
  qlw_marker="${qlw_marker%/}/claude-question-leak-warn-$qlw_sid"
fi
if [ "$qlw_active" != 1 ]; then
  # A new turn: forget the last one's warning.
  if [ -n "$qlw_marker" ] && [ -d "$qlw_marker" ]; then rmdir "$qlw_marker" 2>/dev/null; fi
elif [ -z "$qlw_marker" ] || [ -d "$qlw_marker" ]; then
  # A continued turn this hook already warned in, or cannot tell.
  exit 0
fi
if [ "$qlw_mode" != message ] && [ "$qlw_mode" != transcript ]; then exit 0; fi

# qlw_scan — reads the message on stdin; prints the first question line that
# no receipt line follows, or nothing. LC_ALL=C: bytes, the same in every awk.
qlw_scan() {
  LC_ALL=C awk -v receipt="$QLW_RECEIPT_RE" -v keep="$(( (QLW_QUOTE_MAX + 1) * 4 ))" '
    BEGIN { infence = 0; fch = ""; flen = 0; pending = "" }
    {
      line = $0
      sub(/[\r]+$/, "", line)

      t = line
      sub(/^[ \t]+/, "", t)

      # Fenced code: a run of 3+ backticks or tildes opens it; a run of the
      # same character, at least as long, with nothing after it closes it.
      # Inside a fence a line is only content, so the close is read from the
      # line as it stands (a `- ```` line in a code block closes nothing).
      if (infence) {
        if (substr(t, 1, 1) == fch) {
          r = t
          while (substr(r, 1, 1) == fch) r = substr(r, 2)
          if (length(t) - length(r) >= flen && r ~ /^[ \t]*$/) infence = 0
        }
        next
      }

      # The line with its list markers removed: a fence, heading, blockquote,
      # or table row that opens a list item (`- ```bash`, `- > quoted?`) is
      # still one.
      b = t
      while (b ~ /^([-*+]|[0-9]+[.)])[ \t]+/) sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", b)

      c = substr(b, 1, 1)
      if (c == "`" || c == "~") {
        r = b
        while (substr(r, 1, 1) == c) r = substr(r, 2)
        n = length(b) - length(r)
      } else {
        n = 0
      }
      # (A backtick run with another backtick after it is inline code.)
      if (n >= 3 && !(c == "`" && index(r, "`") > 0)) { infence = 1; fch = c; flen = n; next }

      # A receipt answers every question above it: it carries no question
      # text, so it cannot be tied to one line, and the rule is "a question
      # not followed by a receipt" (issue #1778). One inside a fence or a
      # blockquote is an example or a quote, not a receipt. The receipt line
      # itself is still checked below: a question after the receipt on the
      # same line is a new, unanswered one.
      if (b !~ /^>/ && tolower(line) ~ receipt) pending = ""

      # Headings, blockquotes, table rows.
      if (b ~ /^#+([ \t]|$)/ || b ~ /^>/ || b ~ /^[|]/) next

      # A `?` inside inline code is never line-final: the closing backtick
      # is, and backticks are not stripped here.
      sub(/[ \t]+$/, "", t)
      sub(/[*_~]+$/, "", t)
      sub(/[ \t]+$/, "", t)
      if (t !~ /[?]$/) next

      # A bare URL (a list marker at most before it) is not a question, even
      # with a `?` at its end; a sentence that ends in a URL and `?` is.
      w = t
      sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", w)
      if (index(w, "://") > 0 && w !~ /[ \t]/) next

      # Some words, not just punctuation.
      s = t
      gsub(/[ \t?!.,;:*_~()-]/, "", s)
      if (length(s) < 2) next

      if (pending == "") {
        pending = line
        sub(/^[ \t]+/, "", pending)
        sub(/[ \t]+$/, "", pending)
        # Only the first QLW_QUOTE_MAX characters are ever quoted, and the
        # line reaches jq as an argument, which must stay under the OS
        # limit. keep bytes always hold more than that many characters.
        if (length(pending) > keep + 0) pending = substr(pending, 1, keep + 0)
      }
    }
    END { if (pending != "") print pending }
  ' 2>/dev/null
}

# qlw_transcript_jq — the fallback reader's program: the text of the last
# assistant message in a transcript tail. The tail may start mid-record;
# fromjson? drops that line and any other malformed one. The final message can
# span several records that share its message.id (one per content block), so
# the text blocks of all of them are joined.
qlw_transcript_jq() {
  cat <<'JQ'
[inputs | (fromjson? // empty) | select(type == "object" and .type == "assistant")] as $a
| if ($a | length) == 0 then empty else
    ($a | last) as $last
    | (($last | .message? | .id?) // null) as $id
    | (if ($id | type) == "string"
       then [$a[] | select((.message? | .id?) == $id)]
       else [$last] end)
    | [ .[] | .message.content? as $c
        | if ($c | type) == "string" then $c
          elif ($c | type) == "array" then
            ($c[] | select(type == "object" and .type == "text") | .text | strings)
          else empty end ]
    | join("\n") | split("\u0000") | join("")
  end
JQ
}

# qlw_warning_jq — the one warning: the leaked line quoted ($q, cut to $max)
# and the fix human-queue.md names.
qlw_warning_jq() {
  cat <<'JQ'
(if ($q | length) > $max then ($q[0:($max - 3)] + "...") else $q end) as $quote
| {
    hookSpecificOutput: {
      hookEventName: "Stop",
      additionalContext: ("PROSE QUESTION WARNING (human-queue.md): your final message asks in prose: \"" + $quote + "\". A prose question never reaches the human queue, so no desk sees it. "
        + "Fix: ask it through the question tool (AskUserQuestion), recommended option first. "
        + "While a live desk exists the capture hook queues it and denies the menu; print the receipt the denial names, exactly (question D-<n> sent to human queue), then proceed on the recommended default or park. "
        + "With no live desk the menu renders here as usual. With no question tool (headless): proceed on the default or park, recorded in the handoff or exit report. "
        + "If that line is not a question for the operator, end your turn without repeating it.")
    }
  }
JQ
}

case "$qlw_mode" in
  message)
    qlw_q=$(printf '%s' "$qlw_payload" |
      "$qlw_jq" -j '.last_assistant_message | split("\u0000") | join("")' 2>/dev/null |
      qlw_scan) || exit 0
    ;;
  transcript)
    qlw_tp=$(printf '%s' "$qlw_payload" | "$qlw_jq" -r '.transcript_path' 2>/dev/null) || exit 0
    if [ ! -f "$qlw_tp" ] || [ ! -r "$qlw_tp" ]; then exit 0; fi
    qlw_q=$(tail -c "$QLW_TAIL_BYTES" "$qlw_tp" 2>/dev/null |
      "$qlw_jq" -R -n -j "$(qlw_transcript_jq)" 2>/dev/null |
      qlw_scan) || exit 0
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$qlw_q" ] || exit 0

# Record the warning before giving it. In a continued turn the marker must be
# created here, or the warning is not given (mkdir is atomic and never
# follows a symlink, so a planted path only ever silences the hook).
if [ "$qlw_active" = 1 ]; then
  mkdir "$qlw_marker" 2>/dev/null || exit 0
elif [ -n "$qlw_marker" ]; then
  mkdir "$qlw_marker" 2>/dev/null || :
fi

"$qlw_jq" -c -n --arg q "$qlw_q" --argjson max "$QLW_QUOTE_MAX" "$(qlw_warning_jq)" 2>/dev/null

exit 0
