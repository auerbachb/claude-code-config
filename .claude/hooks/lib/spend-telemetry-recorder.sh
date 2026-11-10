#!/bin/bash
# Shared spend/thread-type telemetry recorder — sourced by hooks, never executed directly.
#
# Single authoritative writer for the spend telemetry stream (issue #710).
# Both capture paths funnel through record_spend_telemetry():
#   - spend-session-tracker.sh  (SessionStart)  -> exec_type "thread"
#   - spend-subagent-tracker.sh (SubagentStop)  -> exec_type "inline"
#
# Storage model — everything lives under ~/.claude/. NEVER write telemetry into
# the skills worktree: session-start-sync.sh can `git reset --hard` it away.
#   - ~/.claude/spend-telemetry.log — append-only, one tab-separated line per
#     event. Read by spend-telemetry-report.sh. The line format is a contract;
#     consumers should tolerate unknown trailing fields.
#
# LOG SCHEMA: legacy 8-column TSV rows remain readable. New events append named
# metadata columns after those fields (schema_version=3); the report supports
# both forms. Transcript message rows contain identifiers and usage metadata
# only — never message content.
#
#   event_type  : session_start | subagent_stop
#   exec_type   : thread | inline
#   model_tier  : opus | sonnet | haiku | fable | unknown
#   agent_type  : for subagent_stop: the agent_type field from payload;
#                 for session_start: "session"
#   session_id  : payload value -> $CLAUDE_CODE_SESSION_ID -> $CLAUDE_SESSION_ID -> "unknown"
#   agent_id    : for subagent_stop: the agent_id field; for session_start: ""
#   tokens      : best-effort integer from transcript; empty when unavailable
#
# record_spend_telemetry() is best-effort and always returns 0 — telemetry must
# never break a hook, and both callers are non-blocking.
#
# Observational-only: per safety.md §"Anthropic Quota & Spend Authority", this
# data MUST NOT gate any agent decision, spending estimate, or quota check.

SPEND_TELEMETRY_LOG="${HOME}/.claude/spend-telemetry.log"

# Sanitize a field value for TSV: strip tabs and newlines to prevent log injection.
_spend_sanitize() {
  local raw="${1:-}"
  printf '%s' "${raw}" | LC_ALL=C tr -d '\t\r\n'
}

# Hash stable metadata identifiers with Python's guaranteed SHA-256 instead
# of relying on a system-provided `shasum` binary.
_spend_event_key() {
  python3 - "$@" <<'PY' 2>/dev/null || true
import hashlib, sys
print(hashlib.sha256("\0".join(sys.argv[1:]).encode("utf-8", errors="replace")).hexdigest()[:24])
PY
}

_spend_repo_slug_from_cwd() {
  local cwd="${1:-}" origin="" slug=""
  [ -n "$cwd" ] && command -v git >/dev/null 2>&1 || return 0
  origin="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  python3 - "$origin" <<'PYREPO' 2>/dev/null || true
import re,sys
from urllib.parse import urlsplit
raw=sys.argv[1]
if raw.startswith("git@github.com:"):
    path=raw[len("git@github.com:"):]
else:
    url=urlsplit(raw)
    path=url.path.lstrip("/") if url.hostname=="github.com" and url.scheme in ("http","https","ssh","git") else ""
if path.endswith(".git"): path=path[:-4]
if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",path): print(path.lower())
PYREPO
  return 0
}

# Resolve session id: payload value -> runtime $CLAUDE_CODE_SESSION_ID -> $CLAUDE_SESSION_ID -> "unknown".
# Mirrors the resolution in skill-usage-recorder.sh.
_spend_resolve_session() {
  local session candidate
  for candidate in "${1:-}" "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"; do
    session="$(_spend_sanitize "$candidate")"
    case "$session" in unknown|default|null|undefined|*'$'*|*'{'*|*'}'*) continue ;; esac
    if [[ ${#session} -le 512 && "$session" =~ ^[A-Za-z0-9_.:-]+$ ]]; then printf '%s' "$session"; return 0; fi
  done
  printf unknown
}

# Hook fields are identifiers/paths, never arbitrary JSON values or task text.
_spend_payload_field() {
  python3 -c 'import json,re,sys
try:
 p=json.load(sys.stdin); v=p.get(sys.argv[1]) if isinstance(p,dict) else None
 path=sys.argv[1] in ("cwd","transcript_path","agent_transcript_path","resume_cursor_path_input")
 valid=isinstance(v,str) and ((path and len(v)<=4096) or (not path and len(v)<=512 and re.fullmatch(r"[A-Za-z0-9_.:/@+\[\]-]*",v)))
 print(v if valid else "")
except Exception: print("")' "$2" <<<"$1" 2>/dev/null || true
}

# Best-effort token extraction from a transcript path.
# Attempts to sum token count fields from JSONL transcript lines.
# Returns empty on any failure — never blocks the hook.
_spend_tokens_from_transcript() {
  local transcript_path="${1:-}"
  [ -z "$transcript_path" ] && printf '' && return 0
  [ -f "$transcript_path" ] || { printf ''; return 0; }

  python3 - "$transcript_path" <<'PY' 2>/dev/null || printf ''
import json, sys
path = sys.argv[1]
total = 0
found = False
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            # Look for usage dicts at the top level of each record.
            usage = obj.get("usage") if isinstance(obj, dict) else None
            if isinstance(usage, dict):
                for sub in ("input_tokens", "output_tokens",
                            "cache_read_input_tokens",
                            "cache_creation_input_tokens"):
                    sv = usage.get(sub)
                    if isinstance(sv, (int, float)):
                        total += int(sv)
                        found = True
            # Also accept bare token fields at top level.
            for key in ("input_tokens", "output_tokens"):
                if key in obj and isinstance(obj[key], (int, float)):
                    total += int(obj[key])
                    found = True
except Exception:
    pass
if found:
    print(total)
PY
  return 0
}

# Append one line to the telemetry log.
# Wraps the redirect so open failures are silenced (a trailing 2>/dev/null
# only covers the command's stderr, not the shell's redirection error).
_spend_append_log() {
  local event_type="${1:-}" exec_type="${2:-}" model_tier="${3:-}" \
        agent_type="${4:-}" session_id="${5:-}" agent_id="${6:-}" tokens="${7:-}"

  mkdir -p "$(dirname "$SPEND_TELEMETRY_LOG")" 2>/dev/null || return 1
  { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%FT%TZ)" \
      "$event_type" \
      "$exec_type" \
      "$model_tier" \
      "$agent_type" \
      "$session_id" \
      "$agent_id" \
      "$tokens" \
      >>"$SPEND_TELEMETRY_LOG"; } 2>/dev/null || return 1
  return 0
}

# Serialize complete TSV line writes across concurrent hook processes.
_spend_locked_append_line() {
  local line="${1:-}"
  python3 - "$SPEND_TELEMETRY_LOG" "$line" <<'PY' 2>/dev/null || return 1
import fcntl, os, sys, tempfile, time, uuid
path, line = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".lock", "a", encoding="ascii") as lock:
    deadline=time.monotonic()+.25
    acquired=False
    while True:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired=True
            break
        except BlockingIOError:
            if time.monotonic()>=deadline: break
            time.sleep(.01)
    if acquired:
        with open(path, "a", encoding="utf-8") as output:
            output.write(line + "\n")
            output.flush()
            os.fsync(output.fileno())
    else:
        # Never lose a hook row just because another process holds the bounded
        # append lock. The private spool is drained explicitly by the report
        # refresh path; the hook itself still exits within its normal bound.
        pending_dir=os.path.join(os.path.dirname(path), "spend-telemetry-pending")
        os.makedirs(pending_dir, mode=0o700, exist_ok=True)
        os.chmod(pending_dir, 0o700)
        fd, temporary=tempfile.mkstemp(prefix=".pending-", suffix=".tmp", dir=pending_dir)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as pending:
                pending.write(line + "\n")
                pending.flush()
                os.fsync(pending.fileno())
            final=os.path.join(pending_dir, "pending-"+uuid.uuid4().hex+".tsv")
            os.replace(temporary, final)
            directory_fd=os.open(pending_dir, os.O_RDONLY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
        except Exception:
            try: os.close(fd)
            except OSError: pass
            try: os.unlink(temporary)
            except OSError: pass
            raise
PY
}

# record_spend_telemetry <event_type> <exec_type> <model_tier> <agent_type>
#                        <session_id> <agent_id> <tokens>
#
#   event_type : session_start | subagent_stop
#   exec_type  : thread | inline
#   All fields are sanitized before writing.
#   Always returns 0 — telemetry must never break a hook.
record_spend_telemetry() {
  local event_type="${1:-}" exec_type="${2:-}" model_tier="${3:-}" \
        agent_type="${4:-}" session_id="${5:-}" agent_id="${6:-}" tokens="${7:-}"

  event_type="$(_spend_sanitize "$event_type")"
  exec_type="$(_spend_sanitize "$exec_type")"
  model_tier="$(_spend_sanitize "$model_tier")"
  agent_type="$(_spend_sanitize "$agent_type")"
  session_id="$(_spend_resolve_session "$session_id")"
  agent_id="$(_spend_sanitize "$agent_id")"
  tokens="$(_spend_sanitize "$tokens")"

  [ -z "$event_type" ] && return 0
  [ -z "$exec_type" ] && return 0

  _spend_append_log "$event_type" "$exec_type" "$model_tier" \
                    "$agent_type" "$session_id" "$agent_id" "$tokens" || true
  return 0
}

# Normalize a runtime model identifier to a family for the legacy model_tier
# column. The raw identifier is preserved separately as actual_model.
_spend_model_family() {
  local model="${1:-}" lower
  lower="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *opus*) printf opus ;;
    *sonnet*) printf sonnet ;;
    *haiku*) printf haiku ;;
    *fable*) printf fable ;;
    *) printf unknown ;;
  esac
}

# Append metadata-only event rows. The first eight columns preserve the old
# schema; report readers can therefore consume mixed logs during rollout.
_spend_append_v2() {
  # Bash positional references above $9 require braces (for example ${10}).
  local event_type="${1:-}" exec_type="${2:-}" model_tier="${3:-unknown}" \
        agent_type="${4:-}" session_id="${5:-unknown}" agent_id="${6:-}" \
        tokens="${7:-}" event_key="${8:-}" repo_root="${9:-}" \
        phase="${10:-unknown}" requested_model="${11:-}" \
        requested_source="${12:-unavailable}" actual_model="${13:-}" \
        actual_source="${14:-unavailable}" input_tokens="${15:-}" \
        output_tokens="${16:-}" cache_read="${17:-}" cache_write="${18:-}" \
        cost_usd="${19:-}" cost_source="${20:-unsupported}" task_id="${21:-}" \
        lifecycle="${22:-unknown}" transcript_scope="${23:-}" \
        usage_source="${24:-unavailable}" evidence_json="${25:-}"

  local values field line
  session_id="$(_spend_resolve_session "$session_id")"
  if [ -z "$event_key" ]; then
    event_key="$(_spend_event_key "$event_type" "$exec_type" "$session_id" \
      "$agent_id" "$task_id" "$(date -u +%FT%TZ)" "$$" "$RANDOM")"
  fi
  values=("$event_type" "$exec_type" "$model_tier" "$agent_type" "$session_id" \
          "$agent_id" "$tokens" "3" "$event_key" "$repo_root" "$phase" \
          "$requested_model" "$requested_source" "$actual_model" "$actual_source" \
          "$input_tokens" "$output_tokens" "$cache_read" "$cache_write" \
          "$cost_usd" "$cost_source" "$task_id" "$lifecycle" \
          "$transcript_scope" "$usage_source" "$evidence_json")
  for i in "${!values[@]}"; do
    values[$i]="$(_spend_sanitize "${values[$i]}")"
  done
  mkdir -p "$(dirname "$SPEND_TELEMETRY_LOG")" 2>/dev/null || return 1
  line="$(date -u +%FT%TZ)"
  for field in "${values[@]}"; do line+=$'\t'"$field"; done
  _spend_locked_append_line "$line" || return 1
  return 0
}

# Resolve the declared model default for an agent. This is *requested* metadata
# only; callers must use a runtime/transcript field for actual_model.
_spend_requested_model_from_agent_type() {
  local agent_type="${1:-}" agent_file="" candidate self_dir hooks_dir claude_dir
  agent_type="${agent_type//[^[:alnum:]_.-]/}"
  [ -n "$agent_type" ] || return 0
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  hooks_dir="${self_dir%/lib}"
  claude_dir="${hooks_dir%/hooks}"
  for candidate in "${claude_dir}/agents" "${HOME}/.claude/skills-worktree/.claude/agents"; do
    if [ -f "${candidate}/${agent_type}.md" ]; then agent_file="${candidate}/${agent_type}.md"; break; fi
  done
  [ -n "$agent_file" ] || return 0
  python3 - "$agent_file" <<'PY' 2>/dev/null || true
import re, sys
try:
    content = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    match = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if match:
        model = re.search(r"^model:\s*(\S+)", match.group(1), re.MULTILINE)
        if model:
            print(model.group(1).strip())
except Exception:
    pass
PY
}

# Compatibility wrapper for legacy callers; the shared lookup returns the raw
# declared default and this function retains the old lowercase tier behavior.
_spend_model_tier_from_agent_type() {
  local model=""
  model="$(_spend_requested_model_from_agent_type "${1:-}")"
  [ -n "$model" ] && { printf '%s' "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"; return 0; }
  printf 'unknown'
  return 0
}

# Read only the supported JSONL assistant message envelope's metadata. The
# message body, tool arguments, and all content fields are intentionally ignored.
# Arguments: transcript, exec_type, session_id, agent_id, agent_type, cwd,
#            requested_model, requested_model_source, transcript_scope
record_spend_transcript() {
  local transcript="${1:-}" exec_type="${2:-unknown}" session_id="${3:-unknown}" \
       agent_id="${4:-}" agent_type="${5:-}" cwd="${6:-}" \
       requested_model="${7:-}" requested_source="${8:-unavailable}" \
       transcript_scope="${9:-unknown}" repo_root="${10:-}" repo_slug="${11:-}" \
       cursor_path_input="${12:-}" \
       phase="unknown" cursor_dir="${HOME}/.claude/spend-telemetry-cursors" \
       explicit_repo_metadata=0
  [ "$#" -ge 10 ] && explicit_repo_metadata=1
  [ -f "$transcript" ] || return 0
  session_id="$(_spend_resolve_session "$session_id")"
  if [ "$explicit_repo_metadata" -eq 0 ] && [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    repo_slug="$(_spend_repo_slug_from_cwd "$cwd")"
  fi
  case "$agent_type" in
    phase-a-*|phase-a) phase="phase-a" ;;
    phase-b-*|phase-b) phase="phase-b" ;;
    phase-c-*|phase-c) phase="phase-c" ;;
  esac

  mkdir -p "$(dirname "$SPEND_TELEMETRY_LOG")" "$cursor_dir" 2>/dev/null || return 0
  python3 - "$transcript" "$SPEND_TELEMETRY_LOG" "$cursor_dir" "$exec_type" \
      "$session_id" "$agent_id" "$agent_type" "$cwd" "$repo_root" "$phase" \
      "$requested_model" "$requested_source" "$transcript_scope" "$repo_slug" \
      "$cursor_path_input" <<'PY' 2>/dev/null || true
import fcntl, hashlib, json, os, re, sys, tempfile, time, uuid
from datetime import datetime, timezone

path, log_path, cursor_dir, exec_type, session_id, agent_id, agent_type, cwd, repo_root, phase, requested, requested_source, scope, repo_slug, cursor_path_input = sys.argv[1:]
families = ("opus", "sonnet", "haiku", "fable")

def identifier(value):
    if not isinstance(value, str) or value in ("unknown", "default", "null", "undefined"):
        return ""
    return value if len(value) <= 512 and re.fullmatch(r"[A-Za-z0-9_.:/@+\[\]-]+", value) else ""

def family(model):
    return next((tier for tier in families if tier in model.lower()), "unknown")

def safe(value):
    return re.sub(r"[\t\r\n]", "", str(value if value is not None else ""))

def marker(line):
    try:
        row = json.loads(line)
        msg = row.get("message") if isinstance(row.get("message"), dict) else {}
        meta = {k: row.get(k) for k in ("uuid", "type", "timestamp", "requestId")}
        meta["message_id"] = msg.get("id")
        return hashlib.sha256(json.dumps(meta,sort_keys=True).encode()).hexdigest()
    except Exception:
        return None

def lock_until(lock, deadline):
    while time.monotonic() < deadline:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            time.sleep(.01)
    return False

absolute_path = os.path.realpath(path)
legacy_adoption = False
if not cursor_path_input:
    # New cursors use canonical source identity so equal relative path strings
    # from different worktrees cannot collide. If an existing legacy cursor
    # uses the raw runtime path, retain it only when its saved absolute source
    # proves it is this same transcript.
    legacy_key = hashlib.sha256("\0".join((session_id, agent_id, scope, path)).encode("utf-8", errors="replace")).hexdigest()
    legacy_path = os.path.join(cursor_dir, legacy_key + ".offset")
    try:
        legacy_saved = json.load(open(legacy_path, encoding="utf-8"))
        legacy_meta = legacy_saved.get("metadata", {}) if isinstance(legacy_saved, dict) else {}
        current_stat = os.stat(path)
        if (isinstance(legacy_meta, dict) and
                legacy_meta.get("cursor_identity") == legacy_key and
                legacy_meta.get("cursor_path_input") == path and
                legacy_meta.get("transcript_path") == os.path.abspath(path) and
                legacy_saved.get("device") == current_stat.st_dev and
                legacy_saved.get("inode") == current_stat.st_ino):
            cursor_path_input = path
            legacy_adoption = True
        else:
            cursor_path_input = absolute_path
    except (OSError, ValueError, TypeError):
        cursor_path_input = absolute_path
cursor_key = hashlib.sha256("\0".join((session_id, agent_id, scope, cursor_path_input)).encode("utf-8", errors="replace")).hexdigest()
cursor_path = os.path.join(cursor_dir, cursor_key + ".offset")
os.makedirs(cursor_dir, mode=0o700, exist_ok=True)
os.chmod(cursor_dir, 0o700)
cursor_metadata={"cursor_identity":cursor_key,"transcript_path":absolute_path,
                 "cursor_path_input":cursor_path_input,
                 "exec_type":exec_type,"session_id":session_id,"agent_id":agent_id,
                 "agent_type":agent_type,"cwd":cwd,"repo_root":repo_root,"repo_slug":repo_slug,
                 "phase":phase,"transcript_scope":scope}
with open(cursor_path + ".lock", "a", encoding="ascii") as cursor_lock:
    if not lock_until(cursor_lock, time.monotonic()+.25):
        sys.exit(0)
    try:
        saved = json.load(open(cursor_path, encoding="utf-8"))
        if not isinstance(saved,dict): saved = {}
    except Exception:
        saved = {}
    saved_metadata=saved.get("metadata") if isinstance(saved.get("metadata"),dict) else {}
    if legacy_adoption and saved_metadata.get("transcript_path") == os.path.abspath(path):
        # Upgrade legacy symlink/relative path metadata in place only after the
        # legacy key and its exact original source path were verified above.
        saved_metadata = dict(saved_metadata)
        saved_metadata["transcript_path"] = absolute_path
        saved["metadata"] = saved_metadata
    if any(saved_metadata.get(key)!=value for key,value in cursor_metadata.items()):
        saved={}
    with open(path, "rb") as stream:
        stat = os.fstat(stream.fileno())
        offset = saved.get("offset",0)
        same_file = saved.get("device")==stat.st_dev and saved.get("inode")==stat.st_ino
        same_size_rewrite = saved.get("size")==stat.st_size and saved.get("mtime_ns")!=stat.st_mtime_ns
        if type(offset) is not int or not same_file or same_size_rewrite or offset<0 or offset>stat.st_size:
            offset = 0
        if offset and saved.get("boundary_key") and isinstance(saved.get("boundary_offset"),int):
            stream.seek(saved["boundary_offset"])
            if marker(stream.readline()) != saved["boundary_key"]: offset=0
        stream.seek(offset)
        new_offset=offset
        boundary_offset=saved.get("boundary_offset",0) if offset else 0
        boundary_key=saved.get("boundary_key") if offset else None
        out=[]
        scanned=0
        deadline_seconds=2 if exec_type=="inline" else 20
        if exec_type=="inline" and os.environ.get("CLAUDE_SPEND_TELEMETRY_TEST_MODE")=="1":
            try:
                override=float(os.environ.get("CLAUDE_SPEND_TELEMETRY_TEST_INLINE_BUDGET", "2"))
                if 0<=override<=2: deadline_seconds=override
            except (TypeError, ValueError): pass
        deadline=time.monotonic()+deadline_seconds

        def append_rows(rows):
            if not rows: return
            def spool_rows():
                pending_dir=os.path.join(os.path.dirname(log_path), "spend-telemetry-pending")
                os.makedirs(pending_dir, mode=0o700, exist_ok=True)
                os.chmod(pending_dir, 0o700)
                for row_line in rows:
                    fd, temporary=tempfile.mkstemp(prefix=".pending-", suffix=".tmp", dir=pending_dir)
                    try:
                        os.fchmod(fd,0o600)
                        with os.fdopen(fd,"w",encoding="utf-8") as pending:
                            pending.write(row_line.rstrip("\n")+"\n")
                            pending.flush()
                            os.fsync(pending.fileno())
                        final=os.path.join(pending_dir,"pending-"+uuid.uuid4().hex+".tsv")
                        os.replace(temporary,final)
                    except Exception:
                        try: os.close(fd)
                        except OSError: pass
                        try: os.unlink(temporary)
                        except OSError: pass
                        raise
                directory_fd=os.open(pending_dir,os.O_RDONLY)
                try: os.fsync(directory_fd)
                finally: os.close(directory_fd)
            with open(log_path+".lock","a",encoding="ascii") as log_lock:
                acquired=lock_until(log_lock,time.monotonic()+.25)
                if acquired:
                    with open(log_path,"a",encoding="utf-8") as log:
                        log.write("".join(rows))
                        log.flush()
                        os.fsync(log.fileno())
                    return
            spool_rows()

        def checkpoint():
            nonlocal_state={"offset":new_offset,"device":stat.st_dev,"inode":stat.st_ino,
                            "boundary_offset":boundary_offset,"boundary_key":boundary_key,
                            "size":stat.st_size,"mtime_ns":stat.st_mtime_ns,
                            "metadata":cursor_metadata}
            append_rows(out)
            out.clear()
            temporary=cursor_path+".tmp-"+str(os.getpid())
            fd=os.open(temporary, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
            with os.fdopen(fd,"w",encoding="utf-8") as cursor:
                os.fchmod(cursor.fileno(),0o600)
                json.dump(nonlocal_state,cursor)
                cursor.flush()
                os.fsync(cursor.fileno())
            os.replace(temporary,cursor_path)

        while time.monotonic()<deadline:
            row_offset=stream.tell()
            line=stream.readline()
            if not line or not line.endswith(b"\n"): break
            new_offset=stream.tell(); boundary_offset=row_offset; boundary_key=marker(line)
            scanned+=1
            try: row=json.loads(line)
            except Exception: row={}
            if isinstance(row,dict) and row.get("type")=="assistant":
                message=row.get("message") if isinstance(row.get("message"),dict) else row
                nested_usage=message.get("usage")
                usage=nested_usage if isinstance(nested_usage,dict) else row.get("usage")
                usage=usage if isinstance(usage,dict) else {}
                nested_model=identifier(message.get("model"))
                actual=nested_model or identifier(row.get("model"))
                actual_source=("transcript.message.model" if nested_model and message is not row else "transcript.model") if actual else "unavailable"
                runtime_requested=identifier(row.get("requestedModel"))
                row_requested=runtime_requested or identifier(requested)
                row_requested_source="transcript.requestedModel" if runtime_requested else requested_source
                transcript_session=identifier(row.get("sessionId"))
                row_session=session_id if session_id!="unknown" else (transcript_session or "unknown")
                row_session_source=("hook_or_runtime_env" if session_id!="unknown" else
                                    "transcript.sessionId" if transcript_session else "unavailable")
                message_id=identifier(message.get("id")) or identifier(row.get("uuid"))
                identity_source="message.id" if identifier(message.get("id")) else "transcript.uuid" if identifier(row.get("uuid")) else "transcript_scope_offset"
                timestamp=""
                try:
                    stamp=datetime.fromisoformat(row.get("timestamp", "").replace("Z", "+00:00"))
                    if stamp.tzinfo: timestamp=stamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
                except Exception: pass
                key_material="\0".join((row_session,agent_id,scope,str(stat.st_ino),str(row_offset)))
                event_key=message_id or hashlib.sha256(key_material.encode()).hexdigest()[:24]
                fields=[]
                for name in ("input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens"):
                    value=usage.get(name)
                    fields.append(str(value) if type(value) is int and value>=0 else "")
                total_field=str(sum(map(int,fields))) if all(v!="" for v in fields) else ""
                usage_source=("transcript.message.usage" if isinstance(nested_usage,dict) and message is not row else "transcript.usage") if usage else "unsupported:no_message_usage"
                evidence={"repo_slug":repo_slug,"repo_source":"git.origin"} if repo_slug else {}
                evidence["transcript_id"]=cursor_key
                evidence["session_source"]=row_session_source
                evidence["message_identity_source"]=identity_source
                evidence["source_mtime_ns"]=stat.st_mtime_ns
                evidence["source_offset"]=row_offset
                values=[timestamp,"assistant_message",exec_type,family(actual),agent_type,row_session,agent_id,total_field,"3",event_key,repo_root,phase,row_requested,row_requested_source,actual,actual_source,*fields,"","unsupported:no_authoritative_per_event_cost_field","","unknown",scope,usage_source,json.dumps(evidence,separators=(",",":"))]
                out.append("\t".join(map(safe,values))+"\n")
            if scanned%128==0: checkpoint()
        checkpoint()
        status="complete" if new_offset==os.fstat(stream.fileno()).st_size else "pending_tail"
        at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        scan_key=hashlib.sha256((cursor_key+":"+str(stat.st_ino)+":"+str(new_offset)+":"+status).encode()).hexdigest()[:24]
        evidence={"repo_slug":repo_slug,"repo_source":"git.origin"} if repo_slug else {}
        evidence["transcript_id"]=cursor_key
        values=[at,"transcript_scan",exec_type,"unknown",agent_type,session_id,agent_id,"","3",scan_key,repo_root,phase,"","unavailable","","unavailable","","","","","","unsupported:no_authoritative_per_event_cost_field","","unknown",scope,"transcript_scan:"+status,json.dumps(evidence,separators=(",",":"))]
        append_rows(["\t".join(map(safe,values))+"\n"])

PY
  return 0
}

# Record metadata-only task lifecycle evidence. Human-facing subjects and
# descriptions are deliberately discarded; completion is not verification.
record_spend_task_lifecycle() {
  local lifecycle="${1:-unknown}" task_id="${2:-}" session_id="${3:-unknown}" \
       cwd="${4:-}" agent_id="${5:-}" repo_root="" repo_slug="" \
       evidence_json="{}" event_key=""
  [ -n "$task_id" ] || return 0
  session_id="$(_spend_resolve_session "$session_id")"
  if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    repo_slug="$(_spend_repo_slug_from_cwd "$cwd")"
  fi
  evidence_json="$(python3 - "$repo_slug" <<'PY' 2>/dev/null || printf '{}'
import json, sys
print(json.dumps({"repo_slug": sys.argv[1], "repo_source": "git.origin"} if sys.argv[1] else {}, separators=(",", ":")))
PY
)"
  event_key="$(_spend_event_key "$session_id" "$task_id" "$lifecycle")"
  _spend_append_v2 "task_${lifecycle}" "unknown" "unknown" "task" "$session_id" \
    "$agent_id" "" "$event_key" "$repo_root" "unknown" "" "unavailable" "" \
    "unavailable" "" "" "" "" "" "unsupported:no_authoritative_per_event_cost_field" \
    "$task_id" "$lifecycle" "task_lifecycle" "unavailable" "$evidence_json" || true
}

# Persist an explicitly supplied session/task-to-issue/PR bridge. The caller
# supplies the repository slug and any read-only GitHub evidence; this helper
# never performs network access.
record_spend_correlation() {
  local session_id="${1:-unknown}" repo_root="${2:-}" repo_slug="${3:-}" \
       issue_number="${4:-}" pr_number="${5:-}" task_id="${6:-}" \
       agent_id="${7:-}" source="${8:-explicit}" evidence_json="${9:-}" \
       event_key=""
  [ -n "$evidence_json" ] || evidence_json='{}'
  session_id="$(_spend_resolve_session "$session_id")"
  issue_number="$(_spend_sanitize "$issue_number")"
  pr_number="$(_spend_sanitize "$pr_number")"
  task_id="$(_spend_sanitize "$task_id")"
  agent_id="$(_spend_sanitize "$agent_id")"
  repo_slug="$(_spend_sanitize "$repo_slug")"
  repo_root="$(_spend_sanitize "$repo_root")"
  source="$(_spend_sanitize "$source")"
  [ -n "$issue_number" ] && [ -n "$repo_slug" ] || return 0
  [ "$session_id" != "unknown" ] || [ -n "$pr_number" ] || return 0
  event_key="$(_spend_event_key "$session_id" "$repo_slug" "$issue_number" \
    "$pr_number" "$task_id" "$agent_id")"
  _spend_append_v2 "task_correlation" "thread" "unknown" "correlation" \
    "$session_id" "$agent_id" "" "$event_key" "$repo_root" "unknown" \
    "" "unavailable" "" "unavailable" "" "" "" "" "" \
    "unsupported:no_authoritative_per_event_cost_field" "$task_id" \
    "linked" "correlation" "$source" "$evidence_json" || true
}
