#!/usr/bin/env bash
# desk/tests/shellcheck.test.sh — shellcheck every shell file under desk/
# (issue #1774). Skips with a notice when shellcheck is not installed.
#
# Gates on severity warning and above. The info level is not stable across
# the versions this runs on: ubuntu-latest ships 0.9.0, whose SC2317 flags
# trap handlers and indirectly-invoked functions as unreachable, and 0.11
# replaced that with SC2329. desk/ is clean at every severity under 0.11;
# HQ_SHELLCHECK_SEVERITY=info (or style) re-checks that locally.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP: shellcheck.test.sh — shellcheck is not installed"
  exit 0
fi

SEVERITY="${HQ_SHELLCHECK_SEVERITY:-warning}"
case "$SEVERITY" in
  error|warning|info|style) ;;
  *) echo "HQ_SHELLCHECK_SEVERITY must be error, warning, info, or style" >&2; exit 2 ;;
esac
echo "shellcheck $(shellcheck --version | sed -n 's/^version: //p'), severity >= $SEVERITY"

cd "$HQ_T_DESK_DIR" || { echo "cannot cd to $HQ_T_DESK_DIR" >&2; exit 1; }

FILES=$(find . -type f -name '*.sh' | LC_ALL=C sort)
if [ -z "$FILES" ]; then
  bad "found no shell files under desk/ — the glob is broken"
  hq_t_finish "shellcheck.test.sh"
  exit 1
fi

while IFS= read -r f; do
  [ -n "$f" ] || continue
  # -x follows `source` directives; source-path lets each file name its
  # siblings relative to itself.
  if out=$(shellcheck -x --source-path=SCRIPTDIR --severity="$SEVERITY" "$f" 2>&1); then
    ok "shellcheck clean: desk/${f#./}"
  else
    bad "shellcheck: desk/${f#./}"
    printf '%s\n' "$out"
  fi
done <<EOF
$FILES
EOF

hq_t_finish "shellcheck.test.sh"
