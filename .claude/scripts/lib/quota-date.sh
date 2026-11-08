#!/usr/bin/env bash
# Quota-local date adapter: exact capability probes, bounded by Python's
# monotonic subprocess timeout (the date tool being probed is not the clock).
# Source only. All data is dates/epochs, never profiles or credentials.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  echo 'quota-date.sh: source this library' >&2
  exit 2
fi
QUOTA_DATE_HELPER="${BASH_SOURCE[0]%/*}/quota-date.py"
quota_date_detect() {
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -r "$QUOTA_DATE_HELPER" ]]; then
    printf '%s\n' unavailable
    return 0
  fi
  python3 "$QUOTA_DATE_HELPER" detect
}
quota_date_format() { python3 "$QUOTA_DATE_HELPER" format "$@"; }
quota_date_iso() { python3 "$QUOTA_DATE_HELPER" iso "$@"; }
quota_date_calendar() { python3 "$QUOTA_DATE_HELPER" calendar "$@"; }
