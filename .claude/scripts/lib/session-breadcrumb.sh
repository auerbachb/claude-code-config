#!/usr/bin/env bash
# session-breadcrumb.sh — sourced library, never executed directly (issue #2300).
#
# Bridges the runtime session id that a SessionStart hook receives in its JSON
# payload to commands run later from the Bash tool. Hooks get the payload; the
# Bash tool's environment may not carry CLAUDE_CODE_SESSION_ID or
# CLAUDE_SESSION_ID, so the spend link writer had no session to record.
#
# Storage: ~/.claude/session-breadcrumbs/<sha256(identity)>.txt — one file per
# nearest-claude-ancestor identity (pid + process start time, see
# claude-ancestor.sh). Each file holds exactly two lines:
#   session_id=<id>
#   ts=<UTC ISO 8601>
# Writes are atomic (temp file in the same directory, then rename). A breadcrumb
# is read only from the file named for the caller's own identity digest, so a
# breadcrumb for another process, or a reused pid with a different start time,
# is never returned.
#
# Every function is best-effort: no output and a 0 status on any failure. A
# missing or unreadable breadcrumb yields an empty result, never a fabricated id.
#
# Test-only override: CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY replaces the live
# ancestor identity. Production code never sets it.

_BREADCRUMB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=claude-ancestor.sh
. "$_BREADCRUMB_LIB_DIR/claude-ancestor.sh" 2>/dev/null || true

_breadcrumb_valid_id() {
  local id="${1:-}"
  [[ -n "$id" && "$id" != unknown && ${#id} -le 512 && "$id" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

_breadcrumb_identity() {
  if [[ -n "${CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY:-}" ]]; then
    printf '%s' "$CLAUDE_SESSION_BREADCRUMB_TEST_IDENTITY"
    return 0
  fi
  claude_ancestor_identity 2>/dev/null || true
}

_breadcrumb_digest() {
  local text="${1:-}"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum 2>/dev/null | awk '{print $1}'
  fi
}

_breadcrumb_dir() {
  [[ -n "${HOME:-}" ]] || return 1
  printf '%s/.claude/session-breadcrumbs' "$HOME"
}

# session_breadcrumb_write <session_id>
# Records the id for the caller's own ancestor identity. No-op when the id is
# invalid/unknown or no claude ancestor exists.
session_breadcrumb_write() {
  local sid="${1:-}" ident dg dir tmp
  _breadcrumb_valid_id "$sid" || return 0
  ident="$(_breadcrumb_identity)"
  [[ -n "$ident" ]] || return 0
  dg="$(_breadcrumb_digest "$ident")"
  [[ -n "$dg" ]] || return 0
  dir="$(_breadcrumb_dir)" || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || return 0
  if printf 'session_id=%s\nts=%s\n' "$sid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dir/$dg.txt" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

# session_breadcrumb_read
# Prints the session id recorded for the caller's ancestor identity, or nothing.
session_breadcrumb_read() {
  local ident dg dir file sid
  ident="$(_breadcrumb_identity)"
  [[ -n "$ident" ]] || return 0
  dg="$(_breadcrumb_digest "$ident")"
  [[ -n "$dg" ]] || return 0
  dir="$(_breadcrumb_dir)" || return 0
  file="$dir/$dg.txt"
  [[ -r "$file" ]] || return 0
  sid="$(sed -n 's/^session_id=//p' "$file" 2>/dev/null | head -n 1)"
  _breadcrumb_valid_id "$sid" || return 0
  printf '%s' "$sid"
  return 0
}
