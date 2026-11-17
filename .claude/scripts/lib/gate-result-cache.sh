#!/usr/bin/env bash
# gate-result-cache.sh — short-lived, fail-closed reuse of one merge-gate.sh
# result between polling-state-gate.sh (producer) and escalate-review.sh
# (consumer) inside one poll cycle (issue #2442, slice of #2421).
#
# The gate decides whether unreviewed code merges, so every doubt is a miss and
# a miss means a live gate run. A saved result is returned ONLY when ALL hold:
#   - the file parses and carries the full schema (schema 1, repo, PR, head,
#     base, rc, saved time, and a gate object with met/head_sha/pr_number/
#     owner_repo/missing of the right types);
#   - repo, PR, HEAD SHA and base SHA match what the caller just read live;
#   - it was saved without --allow-nonauthor (a consumer never passes it);
#   - the gate exited 0 (met) or 1 (unmet) and its own `met` agrees with that
#     exit; any other exit (usage, state or gh failure) is never saved. A saved
#     UNMET result is the common case (a waiting cycle) and the safe direction to
#     reuse: the consumer treats it as "not met", exactly as its live run does
#     on exit 1, which routes to no_reviewer (nothing posted). Staleness can only
#     delay a no-review-override verdict by one cycle (the override window is
#     time-based and an unmet result predates it), never create a met or a paid
#     trigger;
#   - it is younger than GATE_CACHE_TTL seconds (default 60) and not from the
#     future.
# New-review invalidation: no cheap REST read names "a review was posted", so
# the lifetime is the guard. The consumer runs seconds after the producer in the
# same cycle, and the lifetime is no longer than the 60s poll interval, so the
# next cycle re-runs the gate. A review landing inside that window only matters
# to the two paid-reviewer arms, which already fail open to today's routing.
# The file lives under ~/.claude/gate-cache/ (never in a worktree), is written
# atomically, and holds no token. A failed write is ignored by the caller.

GATE_CACHE_TTL="${GATE_CACHE_TTL:-60}"

gate_cache_dir() { printf '%s' "${GATE_CACHE_DIR:-$HOME/.claude/gate-cache}"; }

# gate_cache_file <owner/repo> <pr> -> path (fails on unusable input)
gate_cache_file() {
  local or_lc pr="$2"
  or_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$or_lc" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && "$pr" =~ ^[0-9]+$ ]] || return 1
  printf '%s/%s__pr%s.json' "$(gate_cache_dir)" "${or_lc//\//__}" "$pr"
}

# gate_cache_live_shas <pr> [owner/repo] -> "<owner/repo> <head> <base>", or fail.
# One REST call. With no repo, gh resolves {owner}/{repo} from the cwd checkout.
gate_cache_live_shas() {
  local pr="$1" path out
  if [[ -n "${2:-}" ]]; then path="repos/$2/pulls/$pr"; else path="repos/{owner}/{repo}/pulls/$pr"; fi
  out="$(gh api "$path" --jq '[.base.repo.full_name, .head.sha, .base.sha] | join(" ")' 2>/dev/null)" || return 1
  [[ "$out" =~ ^[^[:space:]]+\ [0-9a-f]{40}\ [0-9a-f]{40}$ ]] || return 1
  printf '%s' "$out"
}

# gate_cache_save <owner/repo> <pr> <head> <base> <allow_nonauthor 0|1> <rc> <gate-json>
# Returns 0 saved, 1 not saved. Never prints.
gate_cache_save() {
  local or="$1" pr="$2" head="$3" base="$4" allow="$5" rc="$6" json="$7" f dir tmp now
  f="$(gate_cache_file "$or" "$pr")" || return 1
  [[ "$rc" =~ ^[01]$ && "$allow" =~ ^[01]$ ]] || return 1
  printf '%s' "$json" | jq -e --arg h "$head" --argjson p "$pr" --argjson rc "$rc" \
    'type == "object" and (.met | type) == "boolean" and .met == ($rc == 0) and .head_sha == $h and .pr_number == $p
     and (.owner_repo | type) == "string" and (.missing | type) == "array"' >/dev/null 2>&1 || return 1
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.gate.XXXXXX" 2>/dev/null)" || return 1
  now="$(date +%s)"
  if printf '%s' "$json" | jq -c --arg or "$(printf '%s' "$or" | tr '[:upper:]' '[:lower:]')" \
       --argjson pr "$pr" --arg head "$head" --arg base "$base" --argjson allow "$allow" \
       --argjson rc "$rc" --argjson now "$now" \
       '{schema: 1, saved_epoch: $now, owner_repo: $or, pr: $pr, head_sha: $head, base_sha: $base,
         allow_nonauthor: ($allow == 1), rc: $rc, gate: .}' > "$tmp" 2>/dev/null \
     && [[ -s "$tmp" ]] && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# gate_cache_load <owner/repo> <pr> <live_head> <live_base> -> prints gate JSON; 0 hit, 1 miss. A hit may be an unmet result.
gate_cache_load() {
  local or="$1" pr="$2" head="$3" base="$4" f now
  f="$(gate_cache_file "$or" "$pr")" || return 1
  [[ -n "$head" && -n "$base" && -f "$f" && -r "$f" ]] || return 1
  now="$(date +%s)"
  jq -ce --arg or "$(printf '%s' "$or" | tr '[:upper:]' '[:lower:]')" --argjson pr "$pr" \
     --arg head "$head" --arg base "$base" --argjson now "$now" --argjson ttl "$GATE_CACHE_TTL" '
    select(type == "object" and .schema == 1
      and (.saved_epoch | type) == "number" and (.rc | type) == "number"
      and .owner_repo == $or and .pr == $pr and .head_sha == $head and .base_sha == $base
      and .allow_nonauthor == false and (.rc == 0 or .rc == 1)
      and .gate.met == (.rc == 0)
      and ($now - .saved_epoch) >= 0 and ($now - .saved_epoch) < $ttl
      and (.gate | type) == "object" and (.gate.met | type) == "boolean"
      and .gate.head_sha == $head and .gate.pr_number == $pr
      and ((.gate.owner_repo | ascii_downcase) == $or) and (.gate.missing | type) == "array")
    | .gate' "$f" 2>/dev/null
}
