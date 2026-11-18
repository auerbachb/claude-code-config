#!/usr/bin/env bash
# tick-digest-gate.sh — Wake the parent only when a watched state changed; one bounded line when it did (issue #2435).
# catalog: scheduling-monitoring — Compare a tick's state digest to the last one; print nothing when unchanged, one bounded event line when changed
#
# Meant to sit at the end of a persistent Monitor command, so an unchanged tick
# prints nothing (no notification, no parent turn) and a changed tick prints a
# single short line with a pointer to the full record. It never replaces the
# Monitor, the bgwork ceiling watch or the hourly table floor; those keep their
# own output. Full detail stays in the existing records and logs.
#
# USAGE: tick-digest-gate.sh --key KEY [--state-dir DIR] [--digest D]
#            [--what TEXT] [--decision TEXT] [--pointer PATH] [--max-bytes N]
#   --key KEY        Watched thing, e.g. pr-2435 (letters, digits, . _ - only).
#   --state-dir DIR  Where the last digest is kept (default ~/.claude/tick-digests).
#   --digest D       The tick's digest. Omitted: sha256 of stdin (any size).
#   --what TEXT      What changed, one line.
#   --decision TEXT  The next decision the parent must make, if any.
#   --pointer PATH   Where the full record lives.
#   --max-bytes N    Cap on the emitted line (default 400, minimum 80).
#
# EXIT STATUS: 0 changed, event line printed; 10 unchanged, nothing printed;
#   11 first observation — baseline stored, nothing printed (a first tick never
#   wakes the parent); 2 usage error; 4 digest could not be stored — the event
#   line is still printed (failing toward waking the parent, never toward silence).
set -euo pipefail
export LC_ALL=C

key=""; state_dir="${HOME:-/tmp}/.claude/tick-digests"; digest=""
what=""; decision=""; pointer=""; max_bytes=400
usage() { sed -n '2,25p' "$0"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key|--state-dir|--digest|--what|--decision|--pointer|--max-bytes)
      [[ $# -ge 2 ]] || { echo "tick-digest-gate: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --key) key="$2" ;; --state-dir) state_dir="$2" ;; --digest) digest="$2" ;;
        --what) what="$2" ;; --decision) decision="$2" ;; --pointer) pointer="$2" ;;
        --max-bytes) max_bytes="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "tick-digest-gate: unknown option $1" >&2; exit 2 ;;
  esac
done

[[ -n "$key" && "$key" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "tick-digest-gate: --key must match [A-Za-z0-9._-]+" >&2; exit 2; }
[[ "$max_bytes" =~ ^[0-9]+$ ]] || { echo "tick-digest-gate: --max-bytes must be an integer" >&2; exit 2; }
(( max_bytes >= 80 )) || max_bytes=80

if [[ -z "$digest" ]]; then
  digest=$(shasum -a 256 | awk '{print $1}')
fi
digest=$(printf '%s' "$digest" | tr -d '\n\r')
[[ -n "$digest" ]] || { echo "tick-digest-gate: empty digest" >&2; exit 2; }

# One writer per key: a Monitor owns its key. Two concurrent writers can at worst
# emit an extra event (read, compare and store are not one atomic step), which
# fails toward waking the parent, never toward silence. The store itself is an
# atomic rename, so a reader never sees a half-written digest.
file="$state_dir/$key.digest"
last=""
have_last=0
if [[ -r "$file" ]]; then
  last=$(head -n1 "$file" || true)
  have_last=1
fi

store() {
  mkdir -p "$state_dir" 2>/dev/null || return 1
  local tmp
  tmp=$(mktemp "$state_dir/.$key.XXXXXX") || return 1
  printf '%s\n' "$digest" > "$tmp" && mv "$tmp" "$file"
}

if [[ "$have_last" == 1 && "$last" == "$digest" ]]; then
  exit 10
fi
if [[ "$have_last" == 0 ]]; then
  if ! store; then
    # Without a stored baseline every later tick would look like a first one and
    # stay silent forever, so a failed baseline is loud.
    echo "EVENT $key digest baseline could not be stored; unchanged-tick check unavailable"
    echo "tick-digest-gate: cannot store baseline for $key" >&2
    exit 4
  fi
  exit 11
fi

clean() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' ; }
suffix=""
[[ -n "$decision" ]] && suffix="$suffix | next: $(clean "$decision")"
[[ -n "$pointer" ]] && suffix="$suffix | record: $(clean "$pointer")"
head_part="EVENT $key changed"
what_part=""
[[ -n "$what" ]] && what_part=": $(clean "$what")"
# Over the bound: shorten only the free-text "what" so the next decision and the
# record pointer survive; fall back to cutting the whole line if they alone overflow.
room=$(( max_bytes - ${#head_part} - ${#suffix} - 3 ))
if (( ${#head_part} + ${#what_part} + ${#suffix} > max_bytes )) && (( room > 0 )); then
  what_part="${what_part:0:$room}..."
fi
line="$head_part$what_part$suffix"
if (( ${#line} > max_bytes )); then
  line="${line:0:$((max_bytes - 3))}..."
fi
printf '%s\n' "$line"

if ! store; then
  echo "tick-digest-gate: cannot store digest for $key (will re-emit next tick)" >&2
  exit 4
fi
exit 0
