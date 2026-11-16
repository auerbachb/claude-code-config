#!/usr/bin/env bash
# Test harness: stamp the FETCHED fields onto one document (#2406) without a full run,
# so a row shape no real provider emits (no capture time, an unlisted source) can be
# checked directly. Usage: fetched-stamp-harness.sh <tmp-dir> <now-epoch> <doc-json> <lib-dir>
set -u
TMP="$1"; NOW="$2"; DOC="$3"; LIB="$4"
warn() { echo "$*" >&2; }
# shellcheck disable=SC1091
source "$LIB/quota-date.sh"
# shellcheck disable=SC1091
source "$LIB/ai-quotas-report.sh"
QUOTA_DATE_DIALECT="$(quota_date_detect)"
# A fifth argument of "nodate" simulates a host whose date helper is unavailable.
[[ "${5:-}" != nodate ]] || QUOTA_DATE_DIALECT=unavailable
stamp_fetched_field "$DOC"
