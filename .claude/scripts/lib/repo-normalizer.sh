#!/usr/bin/env bash
# lib/repo-normalizer.sh — Shared lowercase normalizer for owner/repo scope keys.
#
# Source this file (do NOT execute it directly) from session-state.sh,
# polling-state-gate.sh, and handoff-state.sh so all three scripts agree on
# the same case-normalization contract (issue #704).
#
# PROBLEM SOLVED
#   session-state.sh's repo_key_from_remote_url() was case-preserving, while
#   polling-state-gate.sh's repo_identity() lowercased. The same repo with a
#   differently-cased remote URL (AuerbachB/Skingod vs auerbachb/skingod)
#   produced two separate .repos scopes, fragmenting PR tracking.
#
# CONTRACT
#   All .repos["<owner>/<name>"] scope keys and ~/.claude/handoffs/{owner}/{repo}/
#   paths MUST be lowercase. Sourcing this library and calling normalize_repo_key()
#   at every derivation point ensures no mixed-case input can create a second scope.
#
# USAGE
#   # In session-state.sh, polling-state-gate.sh, handoff-state.sh:
#   source "$SCRIPT_DIR/lib/repo-normalizer.sh"
#   key="$(normalize_repo_key "$raw_key")"
#
# normalize_repo_key <owner/repo>
#   Prints the lowercase form.  Idempotent — already-lowercase input is unchanged.
#   Examples:
#     normalize_repo_key "AuerbachB/Skingod" -> "auerbachb/skingod"
#     normalize_repo_key "auerbachb/myrepo"  -> "auerbachb/myrepo"
#     normalize_repo_key ""                  -> ""

normalize_repo_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}
