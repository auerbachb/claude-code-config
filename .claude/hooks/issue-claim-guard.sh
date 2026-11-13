#!/usr/bin/env bash
# Issue-claim guard — PreToolUse hook (Bash matcher). Issue #2287.
#
# Blocks starting work on an issue-N-* branch unless the claim verdict for
# issue N is `mine`. Covered Bash commands: `git worktree add` (branch from -b/-B,
# or the commit-ish/path), `git checkout -b|-B`, `git switch -c|-C`, and
# `gh pr create` (the current branch, or --head). Commands that name no issue
# branch are allowed and never reach the helper.
#
# Verdicts (from `issue-claim.sh N --check --json`):
#   mine                 allow (cached 60s per checkout + issue + holder)
#   unclaimed | stale    block: run the claim command (stale is taken over there, with a warning)
#   claimed | unknown    block, naming the holder/provider/device/label when known
#   helper missing       block, naming the plain-gh fallback recipe
#   internal fault       block with a DISTINCT "GUARD FAILED" message (never "claimed")
#
# Override: a file $HOME/.claude/issue-claim-overrides/<owner>__<repo>/<N> lets a
# CLAIMED issue N through, for that repo and number only. The user's chat
# instruction (naming the issue) is what the orchestrating agent writes there.
# It never covers `unknown`, `stale`, or any other issue.
#
# Holder: CLAUDE_CLAIM_HOLDER, else CLAUDE_SESSION_ID, else the helper's own
# default (a digest of hostname and checkout) — the same chain the helper uses.
#
# Contract:
#   stdin  — hook JSON {session_id, cwd, tool_name, tool_input:{command}}
#   stdout — hookSpecificOutput JSON with permissionDecision "deny" to block
#   exit 0 always; the decision is carried in the JSON.

set -u

ISSUE_RE='(^|/)issue-([0-9]+)(-|$)'
CACHE_TTL=60
HELPER_TIMEOUT=25

read -r -d '' PY_PARSE <<'PYEOF'
import json, os, re, shlex, sys

def out(status, cwd=""):
    cwd = cwd.replace("\n", " ").replace("\r", " ").replace("\t", " ")
    sys.stdout.write(status + "\t" + cwd + "\n")

raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    d = None
if not isinstance(d, dict):
    out("FAULT:bad-input")
    sys.exit(0)
cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else ""
if d.get("tool_name") != "Bash":
    out("NOTRIGGER", cwd)
    sys.exit(0)
ti = d.get("tool_input")
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str):
    out("FAULT:no-command", cwd)
    sys.exit(0)
if not re.search(r"worktree|checkout|switch|pr\s+create", cmd):
    out("NOTRIGGER", cwd)
    sys.exit(0)
try:
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    toks = list(lex)
except ValueError:
    out("FAULT:unparseable-command", cwd)
    sys.exit(0)

segs, cur = [], []
for t in toks:
    if t in ("&&", "||", ";", "|", "&"):
        segs.append(cur)
        cur = []
    else:
        cur.append(t)
segs.append(cur)

names = []
dir_moved = False
branch_moved = False


ISSUE_NAME = re.compile(r"(^|/)issue-[0-9]+(-|$)")


def attached_value(a, flags):
    # Git also takes the value attached: -bNAME, -cNAME, --create=NAME.
    for f in flags:
        if f.startswith("--"):
            if a.startswith(f + "="):
                return a[len(f) + 1:]
        elif a.startswith(f) and len(a) > len(f):
            return a[len(f):]
    return None


def add_creation(nm, cdir):
    # A dynamic name (shell variable, substitution, glob) cannot be checked: fail closed.
    if re.search(r"[$`*?\[]", nm):
        names.append("UNRESOLVED")
        return
    # Only issue branches are checked, so a non-issue creation never fails closed.
    if not ISSUE_NAME.search(nm):
        return
    # A creation needs the repo it runs in. After a cd, that is unknown here.
    if dir_moved:
        names.append("UNRESOLVED")
    else:
        names.append(nm + "\t" + cdir)


for seg in segs:
    for i, t in enumerate(seg):
        if t == "git":
            j = i + 1
            cdir = ""
            while j < len(seg) and seg[j].startswith("-"):
                if seg[j] == "-C" and j + 1 < len(seg):
                    cdir = seg[j + 1]
                j += 2 if seg[j] in ("-C", "-c") else 1
            if j >= len(seg):
                continue
            sub = seg[j]
            rest = seg[j + 1:]
            if sub == "worktree" and rest[:1] == ["add"]:
                args = rest[1:]
                named, pos, k = [], [], 0
                after_dd = False
                while k < len(args):
                    a = args[k]
                    if not after_dd and a == "--":
                        after_dd = True
                        k += 1
                        continue
                    if not after_dd and a in ("-b", "-B"):
                        if k + 1 < len(args):
                            named.append(args[k + 1])
                        k += 2
                        continue
                    if not after_dd and attached_value(a, ("-b", "-B")) is not None:
                        named.append(attached_value(a, ("-b", "-B")))
                        k += 1
                        continue
                    if not after_dd and a == "--reason":
                        k += 2
                        continue
                    if not after_dd and a.startswith("-"):
                        k += 1
                        continue
                    pos.append(a)
                    k += 1
                if named:
                    for nm in named:
                        add_creation(nm, cdir)
                elif len(pos) >= 2:
                    add_creation(pos[1], cdir)
                elif pos:
                    add_creation(os.path.basename(pos[0].rstrip("/")), cdir)
            elif sub == "checkout" or sub == "switch":
                branch_moved = True
                flags = ("-b", "-B") if sub == "checkout" else ("-c", "-C", "--create", "--force-create")
                for k, a in enumerate(rest):
                    if a in flags and k + 1 < len(rest):
                        add_creation(rest[k + 1], cdir)
                    elif attached_value(a, flags) is not None:
                        add_creation(attached_value(a, flags), cdir)
        if t == "gh" and seg[i + 1:i + 3] == ["pr", "create"]:
            args = seg[i + 3:]
            head = ""
            for k, a in enumerate(args):
                if a in ("--head", "-H") and k + 1 < len(args):
                    head = args[k + 1]
                elif a.startswith("--head="):
                    head = a.split("=", 1)[1]
            if ":" in head:
                head = head.split(":", 1)[1]
            repo_flag = any(a in ("-R", "--repo") or a.startswith("--repo=") for a in args)
            if dir_moved or repo_flag:
                names.append("UNRESOLVED")
            elif head:
                names.append(head + "\t")
            elif branch_moved:
                names.append("UNRESOLVED")
            else:
                names.append("CURRENT")
    if any(tok in ("cd", "pushd", "popd") for tok in seg):
        dir_moved = True

seen = []
for n in names:
    if n and n not in seen:
        seen.append(n)
if not seen:
    out("NOTRIGGER", cwd)
    sys.exit(0)
out("TRIGGER", cwd)
for n in seen:
    sys.stdout.write(n + "\n")
PYEOF

read -r -d '' PY_VERDICT <<'PYEOF' || true
import json, sys

KNOWN = ("mine", "unclaimed", "stale", "claimed", "unknown")
want = sys.argv[1]
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or d.get("verdict") not in KNOWN:
    sys.exit(3)
if str(d.get("issue")) != want:
    sys.exit(3)

def field(key):
    v = d.get(key)
    if not isinstance(v, str) or not v:
        return "-"
    return v.replace("|", "/").replace("\n", " ").replace("\t", " ")

sys.stdout.write("|".join([
    d["verdict"], field("repo"), field("claimant"),
    field("provider"), field("device"), field("label"),
]) + "\n")
PYEOF

read -r -d '' PY_DENY <<'PYEOF' || true
import json, sys
reason = sys.stdin.read()
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason,
}}))
PYEOF

deny() {
  printf '%s' "$1" | python3 -c "$PY_DENY" 2>/dev/null || \
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GUARD FAILED: issue-claim-guard could not render its decision. Treat this as a guard fault, not a claim verdict."}}'
  exit 0
}

# Distinct from every claim message: a fault says the guard did not run.
fault() {
  deny "GUARD FAILED: the issue-claim guard could not verify this command ($1). This is NOT a claim verdict and does not mean another thread holds the issue. Retry once. If it persists, run the plain-gh claim check from .claude/reference/agent-issue-claims-block.md by hand before starting the branch."
}

# Helper resolution: the same three candidates, in the same order, as the skills.
resolve_helper() {
  local cwdx=$1 c
  if [ -n "${HOME:-}" ]; then
    for c in "$HOME/.claude/skills-worktree/.claude/scripts/issue-claim.sh" \
             "$HOME/.claude/scripts/issue-claim.sh"; do
      if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    done
  fi
  c="${cwdx:-$PWD}/.claude/scripts/issue-claim.sh"
  if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  return 1
}

show() {
  if [ "$1" = "-" ]; then printf 'unknown'; else printf '%s' "$1"; fi
}

override_allows() {
  local r=$1 n=$2
  [ -n "${HOME:-}" ] || return 1
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  [ -f "$HOME/.claude/issue-claim-overrides/${r/\//__}/$n" ]
}

decide_issue() {
  local n=$1 br=$2 cwd=$3
  local helper holder top key cdir cfile out rc fields verdict repo claimant prov dev label now cts
  local harg=()

  helper=$(resolve_helper "$cwd") || deny "BLOCKED: issue-claim.sh not found (checked all three paths). Branch $br names issue #$n, and its claim cannot be checked. The claim cannot be checked, so work must not proceed on this branch. The plain-gh check in .claude/reference/agent-issue-claims-block.md shows who holds the issue, but this guard cannot accept its result. Stop and report why if you cannot get a verified claim through issue-claim.sh."

  holder="${CLAUDE_CLAIM_HOLDER:-${CLAUDE_SESSION_ID:-}}"
  if [ -n "$holder" ]; then harg=(--holder "$holder"); fi

  top=$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || top=""
  key="$top|$n|$holder"
  cdir="${TMPDIR:-/tmp}/claude-issue-claim-guard-$(id -u)"
  cfile="$cdir/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  if [ -n "$top" ] && [ -f "$cfile" ]; then
    cts=$(sed -n 1p "$cfile" 2>/dev/null) || cts=""
    now=$(date +%s)
    if [[ "$cts" =~ ^[0-9]+$ ]] && [ $((now - cts)) -ge 0 ] && [ $((now - cts)) -lt "$CACHE_TTL" ]; then
      return 0
    fi
  fi

  command -v perl >/dev/null 2>&1 || fault "perl is needed to bound the helper call"
  out=$(cd "${cwd:-$PWD}" 2>/dev/null && perl -e 'alarm shift; exec @ARGV or exit 127' "$HELPER_TIMEOUT" "$helper" "$n" --check --json ${harg[@]+"${harg[@]}"} 2>/dev/null)
  rc=$?
  case "$rc" in
    0|1|4) ;;
    *) fault "helper exited $rc for issue #$n" ;;
  esac

  fields=$(printf '%s' "$out" | python3 -c "$PY_VERDICT" "$n" 2>/dev/null) || fault "helper output for issue #$n was unreadable"
  IFS='|' read -r verdict repo claimant prov dev label <<< "$fields"
  [ -n "$verdict" ] || fault "helper gave no verdict for issue #$n"

  case "$verdict" in
    mine)
      if [ -n "$top" ]; then
        mkdir -p "$cdir" 2>/dev/null && printf '%s\n' "$(date +%s)" > "$cfile" 2>/dev/null
      fi
      return 0
      ;;
    claimed)
      if override_allows "$repo" "$n"; then return 0; fi
      deny "BLOCKED: issue #$n ($repo) is claimed by another holder: $(show "$claimant"), provider $(show "$prov"), device $(show "$dev"), label $(show "$label"). Do not start branch $br. The claim command is $helper $n --claim, and it will refuse while the claim is live. Only the user can allow starting it, by naming issue #$n in chat."
      ;;
    unknown)
      deny "BLOCKED: the claim state of issue #$n ($repo) is unknown, so it is not permission to start. Do not start branch $br. Re-check with $helper $n --check, and claim with $helper $n --claim once it reads unclaimed or mine."
      ;;
    unclaimed|stale)
      deny "BLOCKED: issue #$n ($repo) has no live claim for this session (verdict: $verdict). Before branch $br is created, claim it with: $helper $n --claim${repo:+ --repo $repo}. A stale claim is taken over there with a warning. Then retry."
      ;;
  esac
  fault "unexpected verdict $verdict for issue #$n"
}

main() {
  local input parsed first status cwd names line name n checked

  input=$(cat) || fault "stdin was unreadable"
  parsed=$(printf '%s' "$input" | python3 -c "$PY_PARSE" 2>/dev/null) || fault "the command parser failed"
  first=$(printf '%s\n' "$parsed" | sed -n '1p')
  status=${first%%$'\t'*}
  cwd=${first#*$'\t'}
  case "$status" in
    NOTRIGGER) exit 0 ;;
    TRIGGER) ;;
    FAULT:*) fault "${status#FAULT:}" ;;
    *) fault "unexpected parser output" ;;
  esac

  names=$(printf '%s\n' "$parsed" | sed -n '2,$p')
  checked=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%$'\t'*}
    dirx=""
    case "$line" in
      *$'\t'*) dirx=${line#*$'\t'} ;;
    esac
    if [ "$name" = "UNRESOLVED" ]; then
      fault "a directory change or branch switch precedes this command, so the repo or branch it acts on cannot be resolved"
    fi
    work="${cwd:-$PWD}"
    if [ -n "$dirx" ]; then
      case "$dirx" in
        /*) work="$dirx" ;;
        *) work="${cwd:-$PWD}/$dirx" ;;
      esac
    fi
    if [ "$name" = "CURRENT" ]; then
      name=$(git -C "$work" symbolic-ref --short -q HEAD 2>/dev/null) || name=""
    fi
    [ -n "$name" ] || continue
    if [[ "$name" =~ $ISSUE_RE ]]; then
      n=${BASH_REMATCH[2]}
    else
      continue
    fi
    case " $checked " in
      *" $n|$work "*) continue ;;
    esac
    checked="$checked $n|$work "
    decide_issue "$n" "$name" "$work"
  done <<< "$names"
  exit 0
}

main
