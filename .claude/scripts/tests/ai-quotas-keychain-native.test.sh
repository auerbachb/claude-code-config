#!/usr/bin/env bash
# catalog: tests — Verify the native service-only Keychain adapter against a private temporary Keychain, preserving fixed synthetic bytes, ACLs and the user search list
set -euo pipefail
if [[ "$(uname -s)" != Darwin || ! -x /usr/bin/swiftc ]]; then
  echo 'SKIP: native Keychain integration requires macOS Swift'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! /usr/bin/swiftc -D KEYCHAIN_TESTING -parse-as-library \
    "$ROOT/.claude/scripts/lib/ai-quotas-keychain.swift" \
    "$ROOT/.claude/scripts/tests/ai-quotas-keychain-native.swift" \
    -o "$TMP/native-test" > "$TMP/build.log" 2>&1; then
  cat "$TMP/build.log" >&2
  exit 1
fi
"$TMP/native-test" "$TMP/fixture-private.keychain-db"
[[ ! -e "$TMP/fixture-private.keychain-db" ]] || { echo 'FAIL: private test Keychain was not removed'; exit 1; }
