#!/usr/bin/env bash
# catalog: backlog-pm — Mints a durable usage-limit park identity from OS entropy
# Exit 0: one parkgen-<32 lowercase hex> identity; 2: usage; 5: entropy failure.
# Never fall back to clock/PID/RANDOM: completed parks need durable identity.
set -euo pipefail
[[ $# -eq 0 ]] || exit 2
nonce=""
if ! nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') \
   || [[ ! "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
  echo 'park-generation.sh: could not mint a durable park identity; claim nothing' >&2
  exit 5
fi
printf 'parkgen-%s\n' "$nonce"
