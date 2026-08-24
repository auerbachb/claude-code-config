#!/usr/bin/env bash
# portable-handoff-publish.sh — lint and atomically update one canonical note.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=""
REPO=""
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
OUT_DIR="${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}"
LINT_SH="$SCRIPT_DIR/portable-handoff-lint.sh"
LINT_ROOT=""

usage() {
  cat <<'EOF'
Usage: portable-handoff-publish.sh --input FILE --repo owner/name
       [--session ID] [--out-dir DIR] [--lint FILE] [--lint-root DIR]

Publishes one canonical manual /stop handoff per repository/session. The input
must pass portable-handoff-lint.sh before the locked, same-directory atomic
rename. The canonical path is printed on success.

Exit: 0 published | 1 lint violation | 2 usage | 3 unreadable input |
      4 lint/internal unavailable | 5 write failure | 6 lock timeout
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --input|--repo|--session|--out-dir|--lint|--lint-root)
      (( $# >= 2 )) || { echo "portable-handoff-publish.sh: $1 requires a value" >&2; exit 2; }
      key="$1"; value="$2"; shift
      case "$key" in
        --input) INPUT="$value" ;;
        --repo) REPO="$value" ;;
        --session) SESSION_ID="$value" ;;
        --out-dir) OUT_DIR="$value" ;;
        --lint) LINT_SH="$value" ;;
        --lint-root) LINT_ROOT="$value" ;;
      esac ;;
    *) echo "portable-handoff-publish.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$INPUT" && -n "$REPO" ]] || { usage >&2; exit 2; }
[[ -r "$INPUT" ]] || { echo "portable-handoff-publish.sh: input is unreadable: $INPUT" >&2; exit 3; }
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  echo "portable-handoff-publish.sh: --repo must look like owner/name" >&2; exit 2;
}
[[ -n "$SESSION_ID" ]] || SESSION_ID=default
[[ -x "$LINT_SH" ]] || { echo "portable-handoff-publish.sh: lint is unavailable: $LINT_SH" >&2; exit 4; }

mkdir -p "$OUT_DIR" || { echo "portable-handoff-publish.sh: could not create $OUT_DIR" >&2; exit 5; }
OUT_DIR=$(cd "$OUT_DIR" 2>/dev/null && pwd -P) || exit 5
safe_repo=$(printf '%s' "$REPO" | tr '[:upper:]/' '[:lower:]-')
key_material=$(printf '%s\n%s' "$REPO" "$SESSION_ID")
if command -v shasum >/dev/null 2>&1; then
  digest=$(printf '%s' "$key_material" | shasum -a 256 | awk '{print substr($1,1,20)}')
elif command -v sha256sum >/dev/null 2>&1; then
  digest=$(printf '%s' "$key_material" | sha256sum | awk '{print substr($1,1,20)}')
else
  echo "portable-handoff-publish.sh: shasum or sha256sum is required for a collision-resistant canonical key" >&2
  exit 4
fi
[[ -n "$digest" ]] || { echo "portable-handoff-publish.sh: could not derive canonical key" >&2; exit 4; }
OUT="$OUT_DIR/portable-handoff-${safe_repo}-${digest}.md"

[[ -r "$SCRIPT_DIR/state-lock.sh" ]] || { echo "portable-handoff-publish.sh: state-lock.sh is unavailable" >&2; exit 4; }
# shellcheck source=state-lock.sh
source "$SCRIPT_DIR/state-lock.sh"
state_lock_acquire "$OUT" || exit $?
TMP_DOC=""
trap '[[ -z "${TMP_DOC:-}" ]] || rm -f "$TMP_DOC"; state_lock_release' EXIT

TMP_DOC=$(mktemp "$OUT_DIR/.portable-handoff.XXXXXX") || {
  echo "portable-handoff-publish.sh: could not stage in $OUT_DIR" >&2; exit 5;
}
if ! cp "$INPUT" "$TMP_DOC"; then
  echo "portable-handoff-publish.sh: could not stage the input; original remains at $INPUT" >&2
  exit 5
fi
if [[ -n "$LINT_ROOT" ]]; then
  "$LINT_SH" --repo-root "$LINT_ROOT" --quiet "$TMP_DOC"
else
  "$LINT_SH" --quiet "$TMP_DOC"
fi
lint_rc=$?
(( lint_rc == 0 )) || {
  (( lint_rc == 1 )) && exit 1
  echo "portable-handoff-publish.sh: lint could not verify the staged input (exit $lint_rc)" >&2
  exit 4
}
if ! chmod 644 "$TMP_DOC"; then
  echo "portable-handoff-publish.sh: could not set canonical note permissions; original remains at $INPUT" >&2
  exit 5
fi
if ! state_lock_assert_held; then
  echo "portable-handoff-publish.sh: canonical lock changed before publish; original remains at $INPUT" >&2
  exit 6
fi
if ! mv "$TMP_DOC" "$OUT"; then
  echo "portable-handoff-publish.sh: atomic publish failed; original remains at $INPUT" >&2
  exit 5
fi
TMP_DOC=""

printf '%s\n' "$OUT"
