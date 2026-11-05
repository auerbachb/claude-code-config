#!/usr/bin/env bash
# catalog: token-measurement — Metadata-only profile layout diagnosis and transactional repair for ai-quotas-setup.sh
# Sourced by ai-quotas-setup.sh. Never opens a credential file.
# shellcheck source=./ai-quotas-layout-keychain.sh
source "$SELF_DIR/lib/ai-quotas-layout-keychain.sh"

layout_physical() { # Resolve existing ancestors without creating anything.
  local probe="$1" rest="" phys
  while [[ ! -d "$probe" ]]; do
    [[ "$probe" != / && "$probe" != . ]] || return 1
    rest="/$(basename "$probe")$rest"
    probe="$(dirname "$probe")"
  done
  phys="$(cd -P "$probe" && pwd -P)" || return 1
  printf '%s%s' "$phys" "$rest"
}

layout_report() { # <config-json> -> findings; paths and credential presence only
  local row provider label dir expected finding detail repairable root_phys actual target rel credential result='[]'
  local keychain_cycle
  keychain_cycle="$(layout_keychain_metadata "$1")"
  root_phys="$(layout_physical "$PROFILE_ROOT")" || root_phys=""
  while IFS= read -r row; do
    provider="$(printf '%s' "$row" | jq -r '.provider')"
    label="$(printf '%s' "$row" | jq -r '.label')"
    dir="$(printf '%s' "$row" | jq -r '.profile_dir')"
    expected="$(profile_dir_for "$label" "$provider")"
    finding=custom; detail='outside label/provider layout'; repairable=false
    case "$provider" in
      claude|codex)
        actual="$(layout_physical "$dir")" || actual=""
        target="$(layout_physical "$expected")" || target=""
        if [[ "$dir" == "$expected" || ( -n "$actual" && "$actual" == "$target" ) ]]; then
          finding=match; detail='label and path agree'
        elif [[ "$dir" == "$PROFILE_ROOT/"*"/$provider" ]]; then
          rel="${dir#"$PROFILE_ROOT/"}"; rel="${rel%"/$provider"}"
          if [[ -n "$rel" && "$rel" != */* && "$rel" != "$label" ]]; then
            finding="label-mismatch"; detail="path label: $rel"
            if printf '%s' "$1" | jq -e --arg p "$provider" --arg l "$rel" 'any(.accounts[]; .provider == $p and .label == $l)' >/dev/null; then
              detail="$detail; swap peer: $rel"
            fi
            repairable=true
          fi
        fi
        if [[ ! -d "$dir" ]]; then finding=missing; detail="missing directory; $detail"; repairable=false; fi
        if [[ "$(printf '%s' "$1" | jq --arg d "$dir" '[.accounts[] | select(.profile_dir == $d)] | length')" -gt 1 ]]; then
          finding=shared; detail='multiple registry records share this directory'; repairable=false
        fi
        if [[ "$actual" != "$root_phys/${dir#"$PROFILE_ROOT/"}" || "$target" != "$root_phys/$label/$provider" ]]; then
          repairable=false; detail="$detail; redirected/custom path"
        fi
        case "$provider" in claude) credential=.credentials.json ;; codex) credential=auth.json ;; esac
        if [[ "$finding" == label-mismatch && -L "$dir/$credential" ]]; then
          repairable=false; detail="$detail; symlinked credential: repair refused"
        fi
        if [[ "$provider" == codex && "$finding" == label-mismatch && ! -s "$dir/auth.json" ]]; then
          repairable=false; detail="$detail; repair requires non-empty file-backed auth.json"
        fi
        if [[ "$provider" == claude && "$finding" == label-mismatch ]] && { [[ -e "$(keychain_sidecar_path "$dir")" || -L "$(keychain_sidecar_path "$dir")" ]] || printf '%s' "$row" | jq -e 'has("credential_ref")' >/dev/null; }; then
          if [[ "$repairable" == true ]] && printf '%s' "$keychain_cycle" | jq -e --arg l "$label" 'any(.[]; .label == $l)' >/dev/null; then
            detail="$detail; observed Keychain cycle (native validation required)"
          else
            repairable=false; detail="$detail; path-derived Keychain binding: unsupported cycle, repair refused"
          fi
        fi
        ;;
      *) finding=skipped; detail='provider has no managed login directory' ;;
    esac
    result="$(printf '%s' "$result" | jq --arg p "$provider" --arg l "$label" --arg d "$dir" --arg e "$expected" --arg f "$finding" --arg t "$detail" --argjson r "$repairable" '. + [{provider:$p,label:$l,profile_dir:$d,expected_profile_dir:$e,finding:$f,detail:$t,repairable:$r}]')"
  done < <(printf '%s' "$1" | jq -c '.accounts[]')
  if [[ -e "$PROFILE_ROOT/.layout-repair" || -L "$PROFILE_ROOT/.layout-repair" ]]; then
    result="$(printf '%s' "$result" | jq '. + [{provider:"-",label:"-",finding:"interrupted-repair",detail:"preserve .layout-repair; manual recovery required",repairable:false}]')"
  fi
  printf '%s\n' "$result"
}

action_doctor() {
  local report config
  config="$(read_config)"
  report="$(layout_report "$config")"
  if [[ "$JSON" -eq 1 ]]; then printf '%s\n' "$report"; else
    printf 'PROVIDER\tLABEL\tFINDING\tSTORED\tEXPECTED\tREPAIRABLE\tDETAIL\n'
    printf '%s' "$report" | jq -r '.[] | [.provider,.label,.finding,.profile_dir,.expected_profile_dir,.repairable,.detail] | @tsv'
    echo 'Display only — never a dispatch gate.'
  fi
  if printf '%s' "$report" | jq -e 'any(.[]; .finding == "label-mismatch" or .finding == "shared" or .finding == "missing" or .finding == "interrupted-repair")' >/dev/null; then return 8; fi
  return 0
}

LAYOUT_SLOTS=()
LAYOUT_SOURCES=()
LAYOUT_TARGETS=()
LAYOUT_PHASES=()
LAYOUT_CREDENTIALS=()
LAYOUT_STAGE=""
LAYOUT_COMMITTED=0

layout_cleanup() {
  local code=$? i entry failed=0
  trap - EXIT
  trap '' HUP INT TERM
  if [[ -n "$LAYOUT_STAGE" && "$LAYOUT_COMMITTED" -eq 0 ]]; then
    layout_keychain_rollback || failed=1
    # First evacuate destinations, then restore sources: cycles cannot collide.
    for ((i=${#LAYOUT_SOURCES[@]}-1; i>=0; i--)); do
      if [[ "${LAYOUT_PHASES[$i]}" -eq 2 ]]; then
        if mv "${LAYOUT_TARGETS[$i]}" "$LAYOUT_STAGE/$i"; then LAYOUT_PHASES[i]=1; else failed=1; fi
      fi
    done
    for ((i=${#LAYOUT_SOURCES[@]}-1; i>=0; i--)); do
      if [[ "${LAYOUT_PHASES[$i]}" -eq 1 ]]; then
        if [[ ! -e "${LAYOUT_SOURCES[$i]}" && ! -L "${LAYOUT_SOURCES[$i]}" ]] && mv "$LAYOUT_STAGE/$i" "${LAYOUT_SOURCES[$i]}"; then LAYOUT_PHASES[i]=0; else failed=1; fi
      fi
    done
  fi
  if [[ "$failed" -eq 1 ]]; then
    echo "${SELF_NAME}: manual recovery required; preserve $LAYOUT_STAGE/plan.json" >&2
    for ((i=0; i<${#LAYOUT_SOURCES[@]}; i++)); do
      case "${LAYOUT_PHASES[$i]}" in
        1) printf 'Remaining rename: %q -> %q\n' "$LAYOUT_STAGE/$i" "${LAYOUT_SOURCES[$i]}" >&2 ;;
        2) printf 'First evacuate: %q -> %q; then restore: %q -> %q\n' "${LAYOUT_TARGETS[$i]}" "$LAYOUT_STAGE/$i" "$LAYOUT_STAGE/$i" "${LAYOUT_SOURCES[$i]}" >&2 ;;
      esac
    done
    layout_keychain_recovery
    code=9
  elif [[ -n "$LAYOUT_STAGE" ]]; then
    # Preserve the recovery plan if an interrupted rename left an unexpected
    # entry (including a signal between mv and updating the phase array).
    for entry in "$LAYOUT_STAGE"/* "$LAYOUT_STAGE"/.[!.]* "$LAYOUT_STAGE"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      [[ "$entry" == "$LAYOUT_STAGE/plan.json" ]] || failed=1
    done
    if [[ "$failed" -eq 1 ]]; then
      echo "${SELF_NAME}: manual recovery required; preserve $LAYOUT_STAGE/plan.json" >&2
      code=9
    else
      rm -f "$LAYOUT_STAGE/plan.json"
      rmdir "$LAYOUT_STAGE" || code=9
    fi
  fi
  state_lock_release || true
  release_relogin_slot
  for ((i=0; i<${#LAYOUT_SLOTS[@]}; i++)); do
    RELOGIN_SLOT_MARKER="${LAYOUT_SLOTS[$i]}"; release_relogin_slot
  done
  layout_keychain_cleanup_helper
  exit "$code"
}

layout_preflight() { # <config> -> LAYOUT_PLAN (metadata only)
  local report row src dst label keychain_cycle
  [[ ! -e "$PROFILE_ROOT/.layout-repair" && ! -L "$PROFILE_ROOT/.layout-repair" ]] || die 5 'interrupted repair exists; preserve .layout-repair for recovery'
  report="$(layout_report "$1")"
  if printf '%s' "$report" | jq -e --arg p "$ARG_PROVIDER" 'any(.[]; .provider == $p and (.finding == "shared" or .finding == "missing"))' >/dev/null; then
    die 5 'repair refused: shared or missing source directory'
  fi
  LAYOUT_PLAN="$(printf '%s' "$report" | jq --arg p "$ARG_PROVIDER" '[.[] | select(.provider == $p and .finding == "label-mismatch")]')"
  keychain_cycle="$(layout_keychain_metadata "$1")"
  LAYOUT_PLAN="$(printf '%s' "$LAYOUT_PLAN" | jq --argjson cycle "$keychain_cycle" 'map(. as $r | ($cycle | map(select(.label == $r.label)) | .[0]) as $k | if .provider == "claude" and $k != null then . + {keychain:$k} else . end)')"
  while IFS= read -r row; do
    [[ "$(printf '%s' "$row" | jq -r '.repairable')" == true ]] || die 5 "repair refused: $(printf '%s' "$row" | jq -r '.detail')"
    label="$(printf '%s' "$row" | jq -r '.label')"
    valid_label "$label" || die 5 'repair refused: invalid registry label'
    [[ "$(printf '%s' "$1" | jq --arg p "$ARG_PROVIDER" --arg l "$label" '[.accounts[] | select(.provider == $p and .label == $l)] | length')" -eq 1 ]] || die 5 'repair refused: duplicate account identity'
    src="$(printf '%s' "$row" | jq -r '.profile_dir')"
    dst="$(printf '%s' "$row" | jq -r '.expected_profile_dir')"
    if [[ -e "$dst" || -L "$dst" ]]; then
      printf '%s' "$LAYOUT_PLAN" | jq -e --arg d "$dst" 'any(.[]; .profile_dir == $d)' >/dev/null || die 5 "repair refused: unregistered target collision at $dst"
    fi
    [[ ! -L "$src" && ! -L "$(dirname "$src")" && ! -L "$dst" && ! -L "$(dirname "$dst")" ]] || die 5 'repair refused: symlink in source/target path'
    if [[ "$ARG_PROVIDER" == claude && ( -e "$(keychain_sidecar_path "$dst")" || -L "$(keychain_sidecar_path "$dst")" ) ]] && ! printf '%s' "$row" | jq -e 'has("keychain")' >/dev/null; then
      die 5 'repair refused: target has a path-derived Keychain binding'
    fi
  done < <(printf '%s' "$LAYOUT_PLAN" | jq -c '.[]')
  layout_keychain_validate
}

action_repair_layout() {
  local config original plan row src dst label i=0 changed credential present
  trap layout_cleanup EXIT
  trap 'exit 5' HUP INT TERM
  layout_keychain_new_repair
  config="$(read_config)"
  layout_preflight "$config"
  plan="$LAYOUT_PLAN"
  [[ "$(printf '%s' "$plan" | jq length)" -gt 0 ]] || { echo 'Nothing to repair.'; return 0; }
  trap layout_cleanup EXIT
  trap 'exit 5' HUP INT TERM
  while IFS= read -r label; do
    ARG_LABEL="$label"
    claim_relogin_slot "$ARG_LABEL" "$ARG_PROVIDER"
    LAYOUT_SLOTS+=("$RELOGIN_SLOT_MARKER"); RELOGIN_SLOT_MARKER=""
  done < <(printf '%s' "$plan" | jq -r '.[].label' | LC_ALL=C sort)
  state_lock_acquire "$CONFIG_FILE" || die 7 'timed out waiting for registry lock'
  # state-lock chains EXIT through release, which loses $? and releases too
  # early for rollback. This transaction owns release and preserves the status.
  trap layout_cleanup EXIT
  original="$config"
  config="$(read_config)"
  layout_preflight "$config"
  [[ "$LAYOUT_PLAN" == "$plan" ]] || die 7 'layout changed while claiming slots; retry'
  # Refuse concurrent registry edits, including additions that introduce aliases.
  [[ "$config" == "$original" ]] || die 7 'registry changed during repair preflight; retry'
  # Ignore termination across staging creation and its ownership assignment.
  trap '' HUP INT TERM
  mkdir -m 700 "$PROFILE_ROOT/.layout-repair" || die 5 'could not create repair staging directory'
  LAYOUT_STAGE="$PROFILE_ROOT/.layout-repair"
  (umask 077; printf '%s\n' "$plan" > "$LAYOUT_STAGE/plan.json") || die 5 'could not write repair plan'
  while IFS= read -r row; do
    src="$(printf '%s' "$row" | jq -r '.profile_dir')"
    dst="$(printf '%s' "$row" | jq -r '.expected_profile_dir')"
    case "$ARG_PROVIDER" in claude) credential=.credentials.json ;; codex) credential=auth.json ;; esac
    present=0; [[ ! -e "$src/$credential" ]] || present=1
    LAYOUT_CREDENTIALS+=("$present")
    LAYOUT_SOURCES+=("$src"); LAYOUT_TARGETS+=("$dst"); LAYOUT_PHASES+=(0)
    if printf '%s' "$row" | jq -e 'has("keychain")' >/dev/null; then
      LAYOUT_KC_OLD+=("$(printf '%s' "$row" | jq -r '.keychain.service')")
      LAYOUT_KC_TARGET+=("$(printf '%s' "$row" | jq -r '.keychain.target_service')")
      LAYOUT_KC_TEMP+=("$(printf '%s' "$row" | jq -r '.keychain.temporary_service')")
      LAYOUT_KC_ACCOUNTS+=("$(printf '%s' "$row" | jq -r '.keychain.account')")
      LAYOUT_KC_PHASES+=(0)
    fi
  done < <(printf '%s' "$plan" | jq -c '.[]')
  trap '' HUP INT TERM
  layout_keychain_stage
  for ((i=0; i<${#LAYOUT_SOURCES[@]}; i++)); do
    mv "${LAYOUT_SOURCES[$i]}" "$LAYOUT_STAGE/$i" || die 5 'could not stage profile; rolling back'
    LAYOUT_PHASES[i]=1
  done
  for ((i=0; i<${#LAYOUT_SOURCES[@]}; i++)); do
    dst="${LAYOUT_TARGETS[$i]}"
    if [[ ! -d "$(dirname "$dst")" ]]; then mkdir -m 700 "$(dirname "$dst")" || die 5 'could not create target parent'; fi
    [[ ! -e "$dst" && ! -L "$dst" ]] || die 5 'target appeared during repair; rolling back'
    mv "$LAYOUT_STAGE/$i" "$dst" || die 5 'could not install profile; rolling back'
    LAYOUT_PHASES[i]=2
    if [[ "${LAYOUT_CREDENTIALS[$i]}" -eq 1 && ! -e "$dst/$credential" ]]; then
      die 5 'credential file disappeared during repair; rolling back'
    fi
  done
  layout_keychain_install
  changed="$(printf '%s' "$config" | jq --argjson plan "$plan" '.accounts |= map(. as $a | ($plan | map(select(.provider == $a.provider and .label == $a.label and .profile_dir == $a.profile_dir)) | .[0]) as $m | if $m == null then . else .profile_dir = $m.expected_profile_dir | if $m.keychain != null then .credential_ref.service = $m.keychain.target_service else . end end)')" || die 5 'could not update repair metadata'
  # Do not roll directories back if termination arrives after publication but
  # before recording its outcome. Write failures still use EXIT rollback.
  trap '' HUP INT TERM
  write_config "$changed"
  LAYOUT_COMMITTED=1
  trap 'exit 5' HUP INT TERM
  printf '%s' "$plan" | jq -r '.[] | "Repaired \(.provider) \(.label): \(.profile_dir) -> \(.expected_profile_dir)"'
}
