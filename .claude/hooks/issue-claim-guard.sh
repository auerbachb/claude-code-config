#!/usr/bin/env bash
# Issue-claim guard — PreToolUse hook (Bash matcher). Issue #2287.
#
# Blocks starting work on a branch named issue-N-* unless the claim verdict for
# issue N is `mine`. It acts ONLY on positive evidence: a branch-creating command
# (`git worktree add ... -b|-B NAME`, `git checkout -b|-B NAME`,
# `git switch -c|-C|--create NAME`, `gh pr create`) whose branch name literally
# contains issue-<digits>. Commands that merely mention those words, unparseable
# text, heredoc bodies, and dynamic branch names ("$X", globs, substitutions) are
# ALLOWED: the GitHub-side check (#2288) covers what this hook cannot see.
#
# Parsing: backslash-newline continuations are joined, comment-only lines dropped,
# heredoc bodies stripped, then the command is tokenised per line. If tokenising
# still fails, a regular-expression scan of the raw text runs instead.
#
# Holder candidates, checked in this order (any `mine` allows):
#   1. CLAUDE_CLAIM_HOLDER (or CLAUDE_SESSION_ID when that is unset)
#   2. the holder recorded at claim time: session-state.sh
#      .repos["<owner/name>"].pipelines["<N>"].claim_holder
#   3. no explicit holder (the helper's own default)
# A failed session-state read is never "no candidate": it blocks (GUARD FAILED)
# unless another candidate reads `mine`.
#
# Verdicts (from `issue-claim.sh N --check --json [--holder H]`):
#   mine                 allow (cached 60s per checkout + issue + holder)
#   unclaimed | stale    block: run the claim command (stale is taken over there)
#   claimed | unknown    block, naming the holder/provider/device/label when known
#   helper missing, helper fault, unreadable helper output: GUARD FAILED block
#
# Override: a file $HOME/.claude/issue-claim-overrides/<owner>__<repo>/<N> lets a
# CLAIMED issue N through for that repo and number only (never `unknown`).
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

ISSUE_NAME = re.compile(r"(^|/)issue-([0-9]+)(-|$)")
DYN_RE = re.compile(r"[$`*?\[~]")
HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_]\w*)\1([^\n]*)\n(?:.*?\n)?[ \t]*\2[ \t]*(?=\n|$)", re.S)
CREATE_FLAGS = {"checkout": ("-b", "-B", "--orphan"), "switch": ("-c", "-C", "--create", "--force-create", "--orphan")}
FALLBACK_VERB = re.compile(r"git\s+worktree\s+add\b|git\s+(?:checkout|switch)\b|gh\s+pr\s+create\b")
FALLBACK_CREATE = re.compile(r"\s-[bBcC]|\s--(?:create|force-create)\b")
FALLBACK_FLAG_ARG = ("-b", "-B", "-c", "-C", "--create", "--force-create", "--orphan")
FALLBACK_ATTACHED = re.compile(r"-[bBcC](.+)$|--(?:create|force-create)=(.+)$")

BASE = os.getcwd()
recs = []
CLAIMS = set()
HOLDER_VAR = "CLAUDE_CLAIM_HOLDER"
# A literal holder: printable, no expansion characters. shlex drops quote
# provenance, so anything carrying $ or a backtick is treated as dynamic.
HOLDER_OK = re.compile(r"^[^\x00-\x1f\x7f$`]{1,512}$")
REPO_OK = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")


def attached(a, flags):
    for f in flags:
        if f.startswith("--"):
            if a.startswith(f + "="):
                return a[len(f) + 1:]
        elif a.startswith(f) and len(a) > len(f):
            return a[len(f):]
    return None


def join(base, p):
    if base == "DYN" or p in ("", "-") or DYN_RE.search(p):
        return "DYN"
    if os.path.isabs(p):
        return os.path.normpath(p)
    return os.path.normpath(os.path.join(base, p))


def add_branch(dirv, nm, holder="-", repo="-"):
    # Dynamic names are not evidence; only literal issue-N branch names count.
    if DYN_RE.search(nm):
        return
    m = ISSUE_NAME.search(nm)
    if not m:
        return
    recs.append(("BRANCH", dirv, m.group(2), nm, holder, repo))


def holder_value(tok):
    # The value of a CLAUDE_CLAIM_HOLDER=VALUE token: the literal, or "" when it
    # is dynamic or unusable (present, but never a candidate).
    v = tok[len(HOLDER_VAR) + 1:]
    return v if HOLDER_OK.match(v) else ""


def seg_holder(seg, i, exported):
    # The holder the command word at seg[i] runs with: the nearest literal
    # prefix assignment (also after `env`), else the exported value.
    found = None
    for tok in seg[:i]:
        if tok.startswith(HOLDER_VAR + "="):
            found = holder_value(tok)
    if found is None:
        found = exported or ""
    return found or "-"


def repo_value(v):
    return v if (v and REPO_OK.match(v)) else "-"


def gh_repo_env(seg, i, exported):
    # The GH_REPO the gh command word at seg[i] runs with ([HOST/]OWNER/REPO):
    # the nearest prefix assignment, else the exported value. None when unset
    # or not a literal repository.
    found = exported
    for tok in seg[:i]:
        if tok.startswith("GH_REPO="):
            found = tok[len("GH_REPO="):]
    if not found:
        return None
    parts = found.split("/")
    if len(parts) == 3:
        found = parts[1] + "/" + parts[2]
    return found if REPO_OK.match(found) else None


def prep(cmd):
    s = cmd.replace("\r\n", "\n").replace("\\\n", "")
    s = HEREDOC.sub(lambda m: "<< " + m.group(2) + m.group(3), s)
    # A command substitution is one dynamic word, not tokens: otherwise its
    # parentheses would hide the command word that follows a VAR=$(...) prefix.
    # A match never spans a quote, separator or newline: a stray $( or backtick
    # in quoted text must not swallow the next command (it would fail open).
    # Repeated until stable, so a nested $(a $(b)) collapses from the inside out.
    n = 1
    while n:
        s, n = re.subn(r"\$\([^()'\"`;&|\n]*\)", "$DYN", s)
    s = re.sub(r"`[^`'\";&|\n]*`", "$DYN", s)
    return "\n".join(l for l in s.split("\n") if not re.match(r"\s*#", l))


def cmd_pos(seg, i):
    # A command word: only wrappers (command, env, exec, VAR=x, options) may precede it.
    return all(tok in ("command", "env", "exec") or "=" in tok or tok.startswith("-") for tok in seg[:i])


def analyse_full(src):
    lex = shlex.shlex(src.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    toks = list(lex)
    segs, cur = [], []
    for t in toks:
        if t in ("&&", "||", ";", "|", "&"):
            segs.append(cur)
            cur = []
        else:
            cur.append(t)
    segs.append(cur)
    dir_t = BASE
    switch_targets = []
    exported = None
    exported_gh = None
    for seg in segs:
        if seg and seg[0] == "export":
            for tok in seg[1:]:
                if tok.startswith(HOLDER_VAR + "="):
                    exported = holder_value(tok)
                elif tok.startswith("GH_REPO="):
                    exported_gh = tok[len("GH_REPO="):]
        elif seg and seg[0] == "unset":
            if HOLDER_VAR in seg[1:]:
                exported = None
            if "GH_REPO" in seg[1:]:
                exported_gh = None
        for k, tok in enumerate(seg):
            if os.path.basename(tok) == "issue-claim.sh" and "--claim" in seg[k + 1:]:
                for a in seg[k + 1:]:
                    if re.match(r"^[1-9][0-9]*$", a):
                        CLAIMS.add(a)
                        break
        if seg and seg[0] in ("cd", "pushd"):
            dir_t = join(dir_t, seg[1]) if len(seg) > 1 else "DYN"
        elif seg and seg[0] == "popd":
            dir_t = "DYN"
        for i, t in enumerate(seg):
            if os.path.basename(t) == "git" and cmd_pos(seg, i):
                hold = seg_holder(seg, i, exported)
                gdir = dir_t
                j = i + 1
                while j < len(seg) and seg[j].startswith("-"):
                    if seg[j] == "-C" and j + 1 < len(seg):
                        gdir = join(gdir, seg[j + 1])
                    j += 2 if seg[j] in ("-C", "-c") else 1
                if j >= len(seg):
                    continue
                sub, rest = seg[j], seg[j + 1:]
                if sub == "worktree" and rest[:1] == ["add"]:
                    args = rest[1:]
                    named, pos, k, after_dd = [], [], 0, False
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
                        if not after_dd and attached(a, ("-b", "-B")) is not None:
                            named.append(attached(a, ("-b", "-B")))
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
                        names = named
                    elif len(pos) >= 2:
                        names = [pos[1]]
                    elif pos:
                        names = [os.path.basename(pos[0].rstrip("/"))]
                    else:
                        names = []
                    for nm in names:
                        add_branch(gdir, nm, hold)
                elif sub in ("checkout", "switch"):
                    flags = CREATE_FLAGS[sub]
                    creating = False
                    for k, a in enumerate(rest):
                        if a in flags and k + 1 < len(rest):
                            creating = True
                            add_branch(gdir, rest[k + 1], hold)
                        elif attached(a, flags) is not None:
                            creating = True
                            add_branch(gdir, attached(a, flags), hold)
                    if not creating:
                        target = next((a for a in rest if not a.startswith("-")), None)
                        if target is not None:
                            switch_targets.append("DYN" if DYN_RE.search(target) else target)
            if os.path.basename(t) == "gh" and cmd_pos(seg, i):
                # gh's global -R/--repo may precede the subcommand; either
                # flag overrides GH_REPO, as in gh itself.
                j, target = i + 1, gh_repo_env(seg, i, exported_gh)
                while j < len(seg) and seg[j].startswith("-"):
                    if seg[j] in ("-R", "--repo") and j + 1 < len(seg):
                        target = seg[j + 1]
                        j += 2
                    elif seg[j].startswith("--repo="):
                        target = seg[j].split("=", 1)[1]
                        j += 1
                    else:
                        j += 1
                if seg[j:j + 2] != ["pr", "create"]:
                    continue
                args = seg[j + 2:]
                head = None
                for k, a in enumerate(args):
                    if a in ("--head", "-H") and k + 1 < len(args):
                        head = args[k + 1]
                    elif a.startswith("--head="):
                        head = a.split("=", 1)[1]
                    elif a in ("--repo", "-R") and k + 1 < len(args):
                        target = args[k + 1]
                    elif a.startswith("--repo="):
                        target = a.split("=", 1)[1]
                hold = seg_holder(seg, i, exported)
                repo = repo_value(target)
                if head is not None:
                    add_branch(dir_t, head.split(":", 1)[1] if ":" in head else head, hold, repo)
                elif switch_targets:
                    if "DYN" not in switch_targets:
                        for s in switch_targets:
                            add_branch(dir_t, s, hold, repo)
                else:
                    recs.append(("CURRENT", dir_t, "-", "-", hold, repo))


def analyse_fallback(src):
    for seg in re.split(r"[;&|\n]+", src):
        m = FALLBACK_VERB.search(seg)
        if not m:
            continue
        rest = seg[m.end():]
        toks = [x.strip("'\"") for x in rest.split()]
        if m.group(0).startswith("gh"):
            for k, a in enumerate(toks):
                head = None
                if a in ("--head", "-H") and k + 1 < len(toks):
                    head = toks[k + 1]
                elif a.startswith("--head="):
                    head = a.split("=", 1)[1]
                if head is not None:
                    add_branch(BASE, head.split(":", 1)[1] if ":" in head else head)
            continue
        if not FALLBACK_CREATE.search(" " + rest):
            continue
        for k, tok in enumerate(toks):
            if tok in FALLBACK_FLAG_ARG and k + 1 < len(toks):
                add_branch(BASE, toks[k + 1])
            else:
                mm = FALLBACK_ATTACHED.match(tok)
                if mm:
                    add_branch(BASE, mm.group(1) or mm.group(2))


def main():
    try:
        d = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(d, dict) or d.get("tool_name") != "Bash":
        return
    ti = d.get("tool_input")
    cmd = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(cmd, str) or not re.search(r"worktree|checkout|switch|pr\s+create", cmd):
        return
    global BASE
    cwd = d.get("cwd")
    if isinstance(cwd, str) and cwd:
        BASE = os.path.normpath(cwd)
    src = prep(cmd)
    try:
        analyse_full(src)
    except Exception:
        recs[:] = []
        CLAIMS.clear()
        analyse_fallback(src)
    if not recs:
        return
    sid = d.get("session_id")
    sid = sid if isinstance(sid, str) and HOLDER_OK.match(sid) else "-"
    claims = ("," + ",".join(sorted(CLAIMS)) + ",") if CLAIMS else "-"
    sys.stdout.write("META\t" + sid + "\t" + claims + "\n")
    seen = set()
    for r in recs:
        if r in seen:
            continue
        seen.add(r)
        sys.stdout.write("\t".join(str(x) for x in r) + "\n")


main()
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
    return "".join(c for c in v if ord(c) >= 32 and ord(c) != 127)

def flag(key):
    v = d.get(key)
    return "true" if v is True else ("false" if v is False else "-")

# Unit separator: a non-whitespace IFS keeps empty fields positional and leaves
# paths containing | intact.
sys.stdout.write("\x1f".join([
    d["verdict"], field("repo"), field("claimant"),
    field("provider"), field("device"), field("label"),
    flag("claimant_is_viewer"), flag("claimant_device_is_local"),
    field("claimant_checkout"), field("claimant_checkout_holder_form"),
    field("claimant_checkout_holder"),
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
resolve_script() {
  local name=$1 cwdx=$2 c
  if [ -n "${HOME:-}" ]; then
    for c in "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
             "$HOME/.claude/scripts/$name"; do
      if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
    done
  fi
  c="${cwdx:-$PWD}/.claude/scripts/$name"
  if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  return 1
}

show() {
  if [ "$1" = "-" ]; then printf 'unknown'; else printf '%s' "$1"; fi
}

override_allows() {
  local r=$1 n=$2 f ts now
  [ -n "${HOME:-}" ] || return 1
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  f="$HOME/.claude/issue-claim-overrides/${r/\//__}/$n"
  [ -f "$f" ] || return 1
  # The file holds its creation time (epoch seconds). It expires after the
  # 4-hour claim stale window; any other content does not allow.
  ts=$(sed -n 1p "$f" 2>/dev/null) || return 1
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [ $((now - ts)) -ge 0 ] && [ $((now - ts)) -lt 14400 ]
}

valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

# Verdict of one holder check, stored in V_*. Returns 0 on `mine` (allow), 1 on
# any other verdict. A helper fault exits through fault().
V_verdict=""; V_repo=""; V_claimant=""; V_prov=""; V_dev=""; V_label=""
V_viewer=""; V_devlocal=""; V_checkout=""; V_ckholder=""

check_holder() {  # n dir helper holder repo
  local n=$1 work=$2 helper=$3 holder=$4 repo=$5
  local top key cdir cfile cts now out rc fields
  local -a harg=()
  if [ -n "$holder" ]; then harg=(--holder "$holder"); fi
  if [ -n "$repo" ]; then harg+=(--repo "$repo"); fi

  top=$(git -C "$work" rev-parse --show-toplevel 2>/dev/null) || top=""
  key="$top|$repo|$n|$holder"
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
  out=$(cd "$work" 2>/dev/null && perl -e 'alarm shift; exec @ARGV or exit 127' "$HELPER_TIMEOUT" "$helper" "$n" --check --json ${harg[@]+"${harg[@]}"} 2>/dev/null)
  rc=$?
  case "$rc" in
    0|1|4) ;;
    *) fault "helper exited $rc for issue #$n" ;;
  esac

  fields=$(printf '%s' "$out" | python3 -c "$PY_VERDICT" "$n" 2>/dev/null) || fault "helper output for issue #$n was unreadable"
  IFS=$'\x1f' read -r V_verdict V_repo V_claimant V_prov V_dev V_label \
    V_viewer V_devlocal V_checkout _ V_ckholder <<< "$fields"
  [ -n "$V_verdict" ] || fault "helper gave no verdict for issue #$n"

  if [ "$V_verdict" = "mine" ]; then
    if [ -n "$top" ]; then
      mkdir -p "$cdir" 2>/dev/null && printf '%s\n' "$(date +%s)" > "$cfile" 2>/dev/null
    fi
    return 0
  fi
  return 1
}

# try_cand HOLDER: one deduplicated candidate check against the target repo.
# Learns the repo from the first helper answer when no literal target exists.
G_seen=""; G_repo=""; G_n=""; G_work=""; G_helper=""
try_cand() {
  local h=$1
  case "$G_seen" in *$'\n'"$h"$'\n'*) return 1 ;; esac
  G_seen="$G_seen$h"$'\n'
  if check_holder "$G_n" "$G_work" "$G_helper" "$h" "$G_repo"; then
    return 0
  fi
  if [ -z "$G_repo" ] && valid_repo "$V_repo"; then G_repo=$V_repo; fi
  return 1
}

# shell_quote VALUE -> one single-quoted shell word.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

check_issue() {  # n dir branch inline-holder target-repo
  local n=$1 work=$2 br=$3 inline=$4 target=$5
  local helper ss key sh rc state_failed=0 rcpt top rh k keys="" sid
  local rshow rflag inclaim="" supplied="" note="" sep="" tok setarg lrepo

  helper=$(resolve_script issue-claim.sh "$work") || deny "GUARD FAILED: issue-claim.sh not found (checked all three paths) for branch $br, which names issue #$n. Its claim cannot be checked, so the branch must not be created. Run the plain-gh claim check in .claude/reference/agent-issue-claims-block.md by hand, and stop with a named reason if that cannot verify the claim."

  G_seen=$'\n'; G_n=$n; G_work=$work; G_helper=$helper; G_repo=""
  if [ "$target" != "-" ] && valid_repo "$target"; then G_repo=$target; fi

  # Candidate 1: a literal CLAUDE_CLAIM_HOLDER on this command (prefix, env
  # prefix, or an earlier export in the same command).
  if [ "$inline" != "-" ]; then
    supplied=1
    try_cand "$inline" && return 0
  fi
  # Candidate 2: the hook environment's explicit holder.
  if [ -n "${CLAUDE_CLAIM_HOLDER:-}" ]; then
    try_cand "$CLAUDE_CLAIM_HOLDER" && return 0
  fi
  # Candidate 3: the session id (environment, else the hook payload's).
  sid="${CLAUDE_SESSION_ID:-}"
  if [ -z "$sid" ] && [ "$PAYLOAD_SESSION" != "-" ]; then sid=$PAYLOAD_SESSION; fi
  if [ -n "$sid" ]; then
    try_cand "$sid" && return 0
  fi

  # Candidate 4: the holder recorded for this issue in session state, under the
  # target repo's key and the checkout's implicit key.
  ss=$(resolve_script session-state.sh "$work") || ss=""
  if [ -z "$ss" ]; then
    state_failed=1
  else
    if [ -n "$G_repo" ]; then keys=$(printf '%s' "$G_repo" | tr 'A-Z' 'a-z'); fi
    if key=$(cd "$work" 2>/dev/null && "$ss" --repo-key 2>/dev/null); then
      key=$(printf '%s' "$key" | tr 'A-Z' 'a-z')
      if [ -n "$key" ] && [ "$key" != "_unknown" ] && [ "$key" != "$keys" ]; then
        keys="$keys${keys:+ }$key"
      fi
    else
      state_failed=1
    fi
    for k in $keys; do
      sh=$(cd "$work" 2>/dev/null && "$ss" --get ".repos[\"$k\"].pipelines[\"$n\"].claim_holder" 2>/dev/null)
      rc=$?
      if [ "$rc" -eq 0 ]; then
        case "$sh" in
          ""|null|_unknown) ;;
          *) try_cand "$sh" && return 0 ;;
        esac
      elif [ "$rc" -ne 3 ]; then
        state_failed=1
      fi
    done
  fi

  # Candidate 5: this worktree's Form A launch receipt. A missing or invalid
  # receipt is no candidate, never a guard fault.
  top=$(git -C "$work" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$G_repo" ] && [ -n "$top" ] && rcpt=$(resolve_script chip-claim-receipt.sh "$work"); then
    if rh=$("$rcpt" read "$top" "$G_repo" "$n" 2>/dev/null) && [ -n "$rh" ]; then
      try_cand "$rh" && return 0
    fi
  fi

  # Candidate 6: no explicit holder (the helper's own default). Always checked
  # last, so its verdict and evidence are the ones reported when nothing reads
  # mine.
  G_seen=$'\n'
  try_cand "" && return 0

  if [ "$state_failed" = "1" ]; then
    fault "the session-state holder for issue #$n could not be read, and no holder checked as mine (last verdict: $V_verdict)"
  fi

  # Recovery text names the target repo only when it is known: never --repo -.
  rshow=${G_repo:-repository not resolved}
  rflag=""
  if [ -n "$G_repo" ]; then rflag=" --repo $G_repo"; fi
  case "$CMD_CLAIMS" in *",$n,"*) inclaim=1 ;; esac
  if [ -n "$supplied" ]; then
    note=" The CLAUDE_CLAIM_HOLDER value supplied in this command does not match the live claim."
  fi

  case "$V_verdict" in
    claimed)
      if override_allows "$G_repo" "$n"; then return 0; fi
      # Own claim, made from a sibling checkout: its default holder is derived
      # locally by the helper (never copied from the GitHub marker).
      if [ "$V_checkout" != "-" ] && [ "$V_ckholder" != "-" ]; then
        tok=$(shell_quote "$V_ckholder")
        setarg=""
        if [ -n "$G_repo" ] && [ -n "$ss" ]; then
          lrepo=$(printf '%s' "$G_repo" | tr 'A-Z' 'a-z')
          setarg=".repos[\"$lrepo\"].pipelines[\"$n\"].claim_holder=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$V_ckholder" 2>/dev/null)"
          setarg=" Or record it once for this pipeline: $ss --repo $G_repo --set $(shell_quote "$setarg"), then retry the command unchanged."
        fi
        deny "BLOCKED: your own claim may not be visible from this checkout. Issue #$n ($rshow) is claimed by this account ($(show "$V_claimant")) under the checkout-default holder of $V_checkout, not of this checkout.$note If this worker made that claim from $V_checkout, the claim is its own: rerun the same command with this prefix: export CLAUDE_CLAIM_HOLDER=$tok && <the same command>.$setarg If this worker did not claim from $V_checkout, another worker holds issue #$n: stop and do not start branch $br. Only the user can allow starting it then, by naming issue #$n in chat."
      fi
      # Own account and device, but a holder no local checkout derives.
      if [ "$V_viewer" = "true" ] && [ "$V_devlocal" = "true" ]; then
        deny "BLOCKED: issue #$n ($rshow) is claimed by this account ($(show "$V_claimant")) on this device ($(show "$V_dev")), under a holder this guard cannot match from this checkout.$note If the claim is this worker's own, rerun the same command with this prefix: export CLAUDE_CLAIM_HOLDER='<your captured holder>' && <the same command>. The holder must come from your own --claim (its --holder, CLAUDE_CLAIM_HOLDER, or the handoff that launched you), never from the GitHub marker. Verify it first with: $helper $n --check --holder '<your captured holder>'$rflag (it must answer mine). If it is not yours, another worker holds it: do not start branch $br. Only the user can allow starting it, by naming issue #$n in chat."
      fi
      deny "BLOCKED: issue #$n ($rshow) is claimed by another holder: $(show "$V_claimant"), provider $(show "$V_prov"), device $(show "$V_dev"), label $(show "$V_label"). Do not start branch $br. The claim command is $helper $n --claim$rflag, and it will refuse while the claim is live.$note Only the user can allow starting it, by naming issue #$n in chat."
      ;;
    unknown)
      deny "BLOCKED: the claim state of issue #$n ($rshow) is unknown, so it is not permission to start. Do not start branch $br. Re-check with $helper $n --check$rflag, and claim with $helper $n --claim$rflag once it reads unclaimed or mine."
      ;;
    unclaimed|stale)
      if [ -n "$inclaim" ]; then
        sep=" The claim in this same command does not count: this guard checks before any part of a command runs. Run $helper $n --claim$rflag as a separate command first, then retry the rest."
      fi
      deny "BLOCKED: issue #$n ($rshow) has no live claim for this session (verdict: $V_verdict). Before branch $br is created, claim it with: $helper $n --claim$rflag. A stale claim is taken over there with a warning. Then retry.$sep"
      ;;
  esac
  fault "unexpected verdict $V_verdict for issue #$n"
}

PAYLOAD_SESSION="-"
CMD_CLAIMS="-"

main() {
  local input parsed kind dirv n name holder trepo br key checked=""

  input=$(cat) || exit 0
  parsed=$(printf '%s' "$input" | python3 -c "$PY_PARSE" 2>/dev/null) || exit 0
  [ -n "$parsed" ] || exit 0

  while IFS=$'\t' read -r kind dirv n name holder trepo; do
    case "$kind" in
      META) PAYLOAD_SESSION=${dirv:--}; CMD_CLAIMS=${n:--}; continue ;;
      BRANCH) br="$name" ;;
      CURRENT) br="" ;;
      *) continue ;;
    esac
    holder=${holder:--}; trepo=${trepo:--}
    if [ "$dirv" = "DYN" ]; then
      # A branch literally named issue-N is evidence, but the repo it lands in
      # cannot be resolved: fault. A current-branch check with an unknown
      # directory is not evidence, so it is allowed.
      if [ "$kind" = "BRANCH" ]; then
        fault "a directory change or -C path precedes the issue branch $br, so the repo it acts on cannot be resolved"
      fi
      continue
    fi
    if [ "$kind" = "CURRENT" ]; then
      br=$(git -C "$dirv" symbolic-ref --short -q HEAD 2>/dev/null) || br=""
      [ -n "$br" ] || continue
      if [[ "$br" =~ $ISSUE_RE ]]; then
        n=${BASH_REMATCH[2]}
      else
        continue
      fi
    fi
    key=" $n|$dirv "
    case "$checked" in
      *"$key"*) continue ;;
    esac
    checked="$checked$key"
    check_issue "$n" "$dirv" "$br" "$holder" "$trepo"
  done <<< "$parsed"
  exit 0
}

main
