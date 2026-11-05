#!/usr/bin/env bash
# Attribute-only Keychain support for fully observed Claude layout cycles.

LAYOUT_KC_OLD=()
LAYOUT_KC_TARGET=()
LAYOUT_KC_TEMP=()
LAYOUT_KC_ACCOUNTS=()
LAYOUT_KC_PHASES=()
LAYOUT_NATIVE_DIR=""
LAYOUT_NATIVE_BIN=""
LAYOUT_REPAIR_ID=""

layout_keychain_new_repair() { LAYOUT_REPAIR_ID="$$-$RANDOM"; }

layout_keychain_metadata() { # Pure registry/sidecar metadata; safe for doctor.
  local out
  if [[ "$PLATFORM" != Darwin ]] || ! command -v python3 >/dev/null 2>&1; then
    printf '[]\n'; return 0
  fi
  if out="$(printf '%s' "$1" | python3 "$SELF_DIR/lib/ai-quotas-keychain-plan.py" "$PROFILE_ROOT" 2>/dev/null)" \
      && printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s\n' "$out"
  else
    printf '[]\n'
  fi
}

layout_keychain_prepare() {
  [[ -z "$LAYOUT_NATIVE_BIN" ]] || return 0
  if [[ -n "${AI_QUOTAS_KEYCHAIN_ADAPTER_BIN:-}" ]]; then
    [[ -x "$AI_QUOTAS_KEYCHAIN_ADAPTER_BIN" ]] || die 5 'Keychain metadata adapter is not executable'
    LAYOUT_NATIVE_BIN="$AI_QUOTAS_KEYCHAIN_ADAPTER_BIN"
    return 0
  fi
  [[ "$PLATFORM" == Darwin && -x /usr/bin/swiftc ]] || die 5 'Keychain cycle repair requires macOS and the Swift compiler'
  LAYOUT_NATIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-quotas-keychain.XXXXXX")" || die 5 'could not create private native-helper directory'
  if ! /usr/bin/swiftc -parse-as-library "$SELF_DIR/lib/ai-quotas-keychain.swift" \
      -o "$LAYOUT_NATIVE_DIR/adapter" > "$LAYOUT_NATIVE_DIR/build.log" 2>&1; then
    tail -n 20 "$LAYOUT_NATIVE_DIR/build.log" >&2 || true
    die 5 'could not compile the Keychain metadata adapter'
  fi
  LAYOUT_NATIVE_BIN="$LAYOUT_NATIVE_DIR/adapter"
}

layout_keychain_call() {
  [[ -n "$LAYOUT_NATIVE_BIN" ]] || return 5
  "$LAYOUT_NATIVE_BIN" "$@"
}

layout_keychain_validate() { # Enrich LAYOUT_PLAN; never reads item data.
  local count i row service target api temporary account metadata bin version
  count="$(printf '%s' "$LAYOUT_PLAN" | jq '[.[] | select(has("keychain"))] | length')"
  [[ "$count" -gt 0 ]] || return 0
  [[ "$count" -eq "$(printf '%s' "$LAYOUT_PLAN" | jq length)" ]] || die 5 'mixed credential stores cannot be repaired as a Keychain cycle'
  bin="$(provider_bin claude)" || die 5 'verified Claude CLI is required for Keychain cycle repair'
  version="$("$bin" --version 2>/dev/null)" || die 5 'could not identify Claude CLI version'
  [[ "$version" == '2.1.312 (Claude Code)' ]] || die 5 'Keychain cycle binding is verified for Claude Code 2.1.312 only'
  account="$(id -un)" || die 5 'could not identify the Claude Keychain account'
  layout_keychain_prepare
  for ((i=0; i<count; i++)); do
    row="$(printf '%s' "$LAYOUT_PLAN" | jq --argjson i "$i" '.[$i].keychain')"
    service="$(printf '%s' "$row" | jq -r '.service')"
    target="$(printf '%s' "$row" | jq -r '.target_service')"
    api="$(printf '%s' "$row" | jq -r '.api_service')"
    temporary="${KEYCHAIN_SERVICE_PREFIX}-layout-${LAYOUT_REPAIR_ID}-${i}"
    metadata="$(layout_keychain_call inspect "$service")" || die 5 'source Keychain metadata unavailable; nothing was moved'
    printf '%s' "$metadata" | jq -e --arg a "$account" '.accounts == [$a]' >/dev/null \
      || die 5 'source Keychain service is absent, ambiguous, or belongs to another OS account'
    metadata="$(layout_keychain_call inspect "$api")" || die 5 'alternate Keychain metadata unavailable'
    printf '%s' "$metadata" | jq -e '.accounts == []' >/dev/null \
      || die 5 'alternate path-bound API-key storage requires separate migration'
    metadata="$(layout_keychain_call inspect "$temporary")" || die 5 'temporary Keychain metadata unavailable'
    printf '%s' "$metadata" | jq -e '.accounts == []' >/dev/null \
      || die 5 'temporary Keychain service collision; nothing was moved'
    LAYOUT_PLAN="$(printf '%s' "$LAYOUT_PLAN" | jq --argjson i "$i" --arg a "$account" --arg t "$temporary" \
      '.[$i].keychain += {account:$a, temporary_service:$t}')"
    # Targets are existing source-path bindings in the validated permutation.
    printf '%s' "$LAYOUT_PLAN" | jq -e --arg s "$target" 'any(.[]; .keychain.service == $s)' >/dev/null \
      || die 5 'unobserved Keychain target binding'
  done
}

layout_keychain_stage() {
  local i
  for ((i=0; i<${#LAYOUT_KC_OLD[@]}; i++)); do
    layout_keychain_call rename "${LAYOUT_KC_OLD[$i]}" "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_ACCOUNTS[$i]}" \
      || die 5 'could not stage Keychain service; rolling back'
    LAYOUT_KC_PHASES[i]=1
  done
}

layout_keychain_install() {
  local i
  for ((i=0; i<${#LAYOUT_KC_OLD[@]}; i++)); do
    layout_keychain_call rename "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_TARGET[$i]}" "${LAYOUT_KC_ACCOUNTS[$i]}" \
      || die 5 'could not install Keychain service binding; rolling back'
    LAYOUT_KC_PHASES[i]=2
  done
}

layout_keychain_rollback() {
  local i failed=0
  for ((i=${#LAYOUT_KC_OLD[@]}-1; i>=0; i--)); do
    if [[ "${LAYOUT_KC_PHASES[$i]}" -eq 2 ]]; then
      if layout_keychain_call rename "${LAYOUT_KC_TARGET[$i]}" "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_ACCOUNTS[$i]}"; then
        LAYOUT_KC_PHASES[i]=1
      else failed=1; fi
    fi
  done
  for ((i=${#LAYOUT_KC_OLD[@]}-1; i>=0; i--)); do
    if [[ "${LAYOUT_KC_PHASES[$i]}" -eq 1 ]]; then
      if layout_keychain_call rename "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_OLD[$i]}" "${LAYOUT_KC_ACCOUNTS[$i]}"; then
        LAYOUT_KC_PHASES[i]=0
      else failed=1; fi
    fi
  done
  [[ "$failed" -eq 0 ]]
}

layout_keychain_recovery() {
  local i
  for ((i=0; i<${#LAYOUT_KC_OLD[@]}; i++)); do
    case "${LAYOUT_KC_PHASES[$i]}" in
      1) printf 'Remaining service rename: %q -> %q\n' "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_OLD[$i]}" >&2 ;;
      2) printf 'First evacuate service: %q -> %q; then restore: %q -> %q\n' "${LAYOUT_KC_TARGET[$i]}" "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_TEMP[$i]}" "${LAYOUT_KC_OLD[$i]}" >&2 ;;
    esac
  done
}

layout_keychain_cleanup_helper() {
  if [[ -n "$LAYOUT_NATIVE_DIR" ]]; then
    # Generated-code cleanup must not replace the transaction outcome.
    rm -f "$LAYOUT_NATIVE_DIR/adapter" "$LAYOUT_NATIVE_DIR/build.log" 2>/dev/null || true
    rmdir "$LAYOUT_NATIVE_DIR" 2>/dev/null || true
  fi
}
