#!/usr/bin/env bash
# pr-outline.sh — the numbered outline of one PR, and any part of it opened
# with context (issue #1768): the desk's drill-down below level 3. Files,
# hunks, and the tests that touch them get numbers the operator can point
# at ("open R-12 2.3"); nothing is stored, and the outline is rebuilt from
# GitHub on every call. Contract: desk/README.md "PR drill-down"; skill:
# desk/skill/drilldown.md.
# catalog: utilities — Human-queue PR drill-down (`desk/bin/pr-outline.sh`): prints a PR's numbered outline (files, hunks, the tests touching each, with line counts) or opens nodes of it (a hunk with twenty lines of context, a whole file's patch); read-only, rebuilt on every call
#
# USAGE
#   pr-outline.sh OWNER/REPO N              the outline
#   pr-outline.sh OWNER/REPO N NODE...      those nodes, opened, in order
#   pr-outline.sh --help
#
#   N is the PR number, or a Review's key pr-N (issue-N exits 3: an issue
#   has no diff). NODE is one of:
#     F      a file (2): its whole patch, a [2.k] marker before each hunk
#     F.H    a hunk (2.3): the hunk with up to twenty more lines of context
#            on each side, as one unified hunk with a recomputed @@ header
#     Tn     a test file (T1), like F
#     Tn.H   a test file's hunk (T1.2), like F.H
#
# THE OUTLINE
#   A header line (`PR OWNER/REPO#N · head SHA · F files · +A -D`), then each
#   file that is not a test, numbered 1, 2, ... in GitHub's order, with its
#   status and +added -deleted; under it, its hunks (2.1, 2.2, ... with the
#   new-side line range, +/- counts, and the hunk's heading) and, as leaves,
#   the tests that touch it (`test T1 PATH · +A -D`). Then `Tests`: every
#   test file the PR changes, numbered T1, T2, ..., the files it touches,
#   and its hunks. A test is a changed path the Reviews view counts as a
#   test (a tests/ or spec/ folder, .test., _test., .spec., test_*); it
#   touches a file when their stems match (widget.test.sh and widget.sh) or
#   its patch names the file's basename. Only tests the PR changes appear.
#   A file GitHub sent no patch for (binary, or too large) has no hunks and
#   says so; a patch whose hunks do not add up to their headers or to the
#   file's counts is marked incomplete.
#
# OPENING A HUNK
#   Each node starts with `=== ID · PATH · ... · head SHA`. A hunk of a
#   changed file is widened from the file at head (one blob fetch per file):
#   up to HQ_OUTLINE_CONTEXT lines (default 20) before and after it, never
#   past a neighbouring hunk (`(context above stops at hunk 2.2)`) or the
#   file's edge (`(start of file)`, `(end of file)`). An added or removed
#   file's hunk is already the whole file. When the file cannot be fetched,
#   or does not match the patch, the hunk prints as GitHub gave it, with
#   one `(more context unavailable: ...)` line.
#
# OUTPUT
#   GitHub's text is untrusted: a CRLF prints as LF, and every other control
#   character but tab and newline prints as "?"; a newline inside a path
#   prints as "?" too, so a path never starts a line. Nothing is written
#   anywhere but stdout: no store, no cache, and the temp files go on exit.
#
# ONE HEAD
#   The file list carries no SHA of its own, so the PR is read again after
#   its files are listed. When a push landed in between, the files are
#   listed again, up to three listings in all, until the head is the same
#   before and after one; the SHA every line cites is that head.
#
# ENVIRONMENT
#   HUMAN_QUEUE_GH           gh binary override (tests point it at a stub)
#   HUMAN_QUEUE_GH_TIMEOUT   seconds each GitHub call may take (default 60)
#   HQ_OUTLINE_CONTEXT       lines of context on each side of an opened hunk
#                            (default 20, at most 500)
#
# EXIT CODES
#   0  ok
#   1  GitHub failed: gh or jq missing, not authenticated, timed out, an
#      answer that could not be read, or a PR pushed to during each of
#      three listings
#   3  no PR with that number, an issue-N key, or a node the outline does
#      not have (the stderr line names the ids it does have); nothing is
#      printed on stdout
#   4  usage: missing or malformed arguments, a node that is not F, F.H, Tn,
#      or Tn.H, a context cap that is not a whole number from 1 to 500
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

hq__self="${BASH_SOURCE[0]}"
while [ -L "$hq__self" ]; do
  hq__link_dir=$(cd -P "$(dirname "$hq__self")" && pwd)
  hq__self=$(readlink "$hq__self")
  case "$hq__self" in
    /*) ;;
    *) hq__self="$hq__link_dir/$hq__self" ;;
  esac
done
HQ_BIN_DIR=$(cd -P "$(dirname "$hq__self")" && pwd)
unset hq__self hq__link_dir

# shellcheck source=lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"

HQ_EXIT_NOT_FOUND=3

usage() {
  sed -n '/^# USAGE/,/^# Bash 3.2/p' "$HQ_BIN_DIR/pr-outline.sh" \
    | sed -e '$d' -e 's/^# \{0,1\}//'
}

die_usage() { hq_die_validation "pr-outline: $*"; }
die_gh() { hq_die_error "pr-outline: $*"; }
die_not_found() { hq_die "$HQ_EXIT_NOT_FOUND" "pr-outline: $*"; }

# The model: GitHub's file list (pages flattened) becomes numbered files,
# hunks, and tests. Input: the slurped pages; $pull: the PR's own JSON.
model_jq() {
  cat <<'JQ'
def num($s): if $s == null or $s == "" then 1 else ($s | tonumber) end;
def is_test: test("(^|/)(tests?|spec|specs|__tests__)/|\\.test\\.|_test\\.|\\.spec\\.|(^|/)test_[^/]*$");
def base: split("/") | last;
def src_stem: base | split(".")[0];
def test_stem: base | split(".")[0] | sub("^test_"; "") | sub("(_test|-test)$"; "");
def esc: gsub("(?<c>[.*+?^${}()|\\[\\]\\\\/])"; "\\\(.c)");
def mentions($b): test("(^|[^A-Za-z0-9_.-])" + ($b | esc) + "($|[^A-Za-z0-9_-])");
# The hunks of one patch, in order. Lines before the first @@ are ignored;
# "\ No newline at end of file" counts as neither side.
def hunks($fid):
  (split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end) as $lines
  | reduce $lines[] as $l ([];
      if ($l | test("^@@ -[0-9]+(,[0-9]+)? \\+[0-9]+(,[0-9]+)? @@")) then
        ($l | capture("^@@ -(?<os>[0-9]+)(,(?<oc>[0-9]+))? \\+(?<ns>[0-9]+)(,(?<nc>[0-9]+))? @@ ?(?<heading>.*)$")) as $h
        | . + [{os: ($h.os | tonumber), oc: num($h.oc), ns: ($h.ns | tonumber), nc: num($h.nc),
                heading: ($h.heading // ""), header: $l, lines: []}]
      elif length == 0 then .
      else .[-1].lines += [$l]
      end)
  | to_entries
  | map(.value + {id: ($fid + "." + ((.key + 1) | tostring))}
        | .add = ([.lines[] | select(startswith("+"))] | length)
        | .del = ([.lines[] | select(startswith("-"))] | length)
        | .ctx = ([.lines[] | select(startswith(" ") or . == "")] | length)
        | .ok = ((.ctx + .del) == .oc and (.ctx + .add) == .nc));
def withhunks($fid):
  . as $f
  | (($f.patch // "") | if . == "" then [] else hunks($fid) end) as $hs
  | $f + {id: $fid, hunks: $hs, has_patch: (($f.patch // "") != ""),
          incomplete: (($f.patch // "") != ""
                       and ((any($hs[]; .ok | not))
                            or ([$hs[].add] | add // 0) != ($f.additions // 0)
                            or ([$hs[].del] | add // 0) != ($f.deletions // 0))),
          got_add: ([$hs[].add] | add // 0), got_del: ([$hs[].del] | add // 0)};

$pullv[0] as $pull
| [.[] | if type == "array" then .[] else . end] as $all
| ($all | map(select(.filename | is_test | not))) as $src
| ($all | map(select(.filename | is_test))) as $tst
| ($src | to_entries | map(.key as $k | .value | withhunks(($k + 1) | tostring))) as $files
| ($tst | to_entries | map(.key as $k | .value | withhunks("T" + (($k + 1) | tostring)))) as $tests0
| ($tests0 | map(. as $t
      | ($t.filename | test_stem) as $ts
      | ($t.patch // "") as $tp
      | $t + {touches: [$files[] | (.filename | base) as $b | select(
            (($ts != "") and (.filename | src_stem) == $ts)
            or (($tp != "") and ($tp | mentions($b)))) | .id]})) as $tests
| { repo: $repo, number: ($pull.number // $number),
    head: ($pull.head.sha // ""),
    changed_files: ($pull.changed_files // ($all | length)),
    listed: ($all | length),
    additions: ($pull.additions // ([$all[].additions] | add // 0)),
    deletions: ($pull.deletions // ([$all[].deletions] | add // 0)),
    files: $files, tests: $tests }
JQ
}

# Shared by the renderers: GitHub's text is untrusted (CRLF to LF, every
# other control character but tab and newline to "?"), and the labels.
lib_jq() {
  cat <<'JQ'
def safe: gsub("\r\n"; "\n") | gsub("\r$"; "")
  | explode
  | map(if (. < 32 and . != 9 and . != 10) or (. >= 127 and . < 160) then 63 else . end)
  | implode;
def short: .[0:7];
# A path is one line: a newline in a filename (git allows one) prints as "?",
# so it can never start a line of its own (a forged node or file line).
def flat: gsub("\n"; "?");
def path_label: if .previous_filename != null and .previous_filename != .filename
                then (.previous_filename | flat) + " → " + (.filename | flat) else .filename | flat end;
def counts: "+" + ((.additions // 0) | tostring) + " -" + ((.deletions // 0) | tostring);
def span($s; $c): if $c == 1 then "line " + ($s | tostring)
                  else "lines " + ($s | tostring) + "-" + (($s + $c - 1) | tostring) end;
def range:
  if .nc > 0 then span(.ns; .nc)
  elif .oc > 0 then "old " + span(.os; .oc)
  else "line " + (.ns | tostring) end;
def heading_label: (.heading // "") | gsub("^\\s+|\\s+$"; "")
  | if . == "" then [] elif length > 60 then [.[0:57] + "..."] else [.] end;
def hunk_line: .id + " " + (([range, ("+" + (.add | tostring) + " -" + (.del | tostring))] + heading_label) | join(" · "));
def file_note:
  if .has_patch | not then
    if .status == "renamed" and (.additions // 0) == 0 and (.deletions // 0) == 0
    then ["renamed only: no content change"]
    else ["no patch (binary, or too large for GitHub to show)"] end
  elif .incomplete then ["patch incomplete (GitHub returned +" + (.got_add | tostring) + " -" + (.got_del | tostring) + ")"]
  else [] end;
def file_line: .id + " " + (([path_label, .status, counts] + file_note) | join(" · "));
def ids_hint($m):
  ([$m.files[].id] as $f | [$m.tests[].id] as $t
   | (if ($f | length) == 0 then [] else ["files " + $f[0] + (if ($f | length) > 1 then "-" + $f[-1] else "" end)] end)
     + (if ($t | length) == 0 then [] else ["tests " + $t[0] + (if ($t | length) > 1 then "-" + $t[-1] else "" end)] end))
  | if length == 0 then "nothing" else join(" and ") end;
JQ
}

outline_jq() {
  cat <<'JQ'
. as $m
| ([ "PR " + $m.repo + "#" + ($m.number | tostring) + " · head " + ($m.head | short) + " · "
     + ($m.changed_files | tostring) + " files · +" + ($m.additions | tostring) + " -" + ($m.deletions | tostring) ]
   + [ $m.files[] | . as $f
       | file_line,
         ($f.hunks[] | "  " + hunk_line),
         ($m.tests[] | select(any(.touches[]; . == $f.id)) | "  test " + .id + " " + (.filename | flat) + " · " + counts) ]
   + (if ($m.tests | length) == 0 then ["", "No test files changed in this PR."]
      else ["", "Tests"]
           + [ $m.tests[]
               | (file_line + " · "
                  + (if (.touches | length) == 0 then "touches no file above"
                     else "touches " + (.touches | join(", ")) end)),
                 (.hunks[] | "  " + hunk_line) ]
      end)
   + (if $m.listed < $m.changed_files
      then ["", "GitHub listed " + ($m.listed | tostring) + " of " + ($m.changed_files | tostring)
                + " changed files; the rest are not in this outline."]
      else [] end))
| join("\n") | safe
JQ
}

# Which nodes the outline lacks: one line naming the first, or nothing.
check_jq() {
  cat <<'JQ'
. as $m
| [ $nodes | split(" ")[] | select(. != "") ] as $want
| [ $want[] as $id
    | ($id | capture("^(?<f>T?[0-9]+)(\\.(?<h>[0-9]+))?$")) as $p
    | ([($m.files + $m.tests)[] | select(.id == $p.f)] | first) as $file
    | if $file == null then "no node " + $id + " in " + $m.repo + "#" + ($m.number | tostring)
                            + " (it has " + ids_hint($m) + ")"
      elif $p.h == null then empty
      elif any($file.hunks[]; .id == $id) then empty
      elif ($file.hunks | length) == 0 then "no hunk " + $id + ": " + $file.id + " has no hunks"
      else "no hunk " + $id + ": " + $file.id + " has " + $file.hunks[0].id
           + (if ($file.hunks | length) > 1 then "-" + $file.hunks[-1].id else "" end) end ]
| first // empty
JQ
}

# One line per node, in order, U+001F-separated: the node, whether its
# rendering wants the file at head, the file's id, and its blob sha.
plan_jq() {
  cat <<'JQ'
. as $m
| [ $nodes | split(" ")[] | select(. != "") ] as $want
| $want[] as $id
| ($id | capture("^(?<f>T?[0-9]+)(\\.(?<h>[0-9]+))?$")) as $p
| ([($m.files + $m.tests)[] | select(.id == $p.f)] | first) as $file
| ([$file.hunks[] | select(.id == $id)] | first) as $h
| [ $id,
    (if $h != null and $h.ok and any(("modified", "renamed", "copied", "changed"); . == $file.status)
        and (($file.sha // "") | test("^[0-9a-f]{40}$"))
     then "fetch" else "none" end),
    $file.id, ($file.sha // "") ]
| join("\u001f")
JQ
}

# One node, rendered. $blob is the file at head (or ""), $have_blob "1" when
# it was fetched, $why the reason it could not be.
node_jq() {
  cat <<'JQ'
. as $m
| ($id | capture("^(?<f>T?[0-9]+)(\\.(?<h>[0-9]+))?$")) as $p
| ([($m.files + $m.tests)[] | select(.id == $p.f)] | first) as $f
| ([range(0; $f.hunks | length) | select($f.hunks[.].id == $id)] | first) as $i
| ("head " + ($m.head | short)) as $headl
| if $p.h == null then
    ([ "=== " + $f.id + " " + (([($f | path_label), $f.status, ($f | counts)] + ($f | file_note) + [$headl]) | join(" · ")) ]
     + (if ($f.hunks | length) == 0 then []
        else [ $f.hunks[] | "[" + .id + "]", .header, .lines[] ] end))
    | join("\n") | safe
  else
    $f.hunks[$i] as $h
    | (if $i > 0 then $f.hunks[$i - 1] else null end) as $prev
    | (if $i + 1 < ($f.hunks | length) then $f.hunks[$i + 1] else null end) as $next
    | ([ "=== " + $h.id + " " + (([($f | path_label), ($h | range),
           ("+" + ($h.add | tostring) + " -" + ($h.del | tostring))] + ($h | heading_label) + [$headl]) | join(" · ")) ]) as $top
    | if ($h.ok | not) then
        ($top + ["(patch incomplete: the hunk is shown as GitHub returned it)", $h.header] + $h.lines)
      elif $f.status == "added" then
        ($top + ["(new file: the hunk is the whole file)", $h.header] + $h.lines)
      elif $f.status == "removed" then
        ($top + ["(removed file: the hunk is the whole file)", $h.header] + $h.lines)
      elif $have_blob != "1" then
        ($top + ["(more context unavailable: " + $why + ")", $h.header] + $h.lines)
      else
        ($blob | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end) as $fl
        | ($fl | length) as $total
        | [ $h.lines[] | select(startswith(" ") or startswith("+") or . == "") | .[1:] ] as $newside
        | (if $h.nc == 0 then [] else $fl[($h.ns - 1):($h.ns - 1 + $h.nc)] end) as $actual
        | if ($h.nc > 0 and $h.ns < 1) or $newside != $actual then
            ($top + ["(more context unavailable: the file at head does not match the patch)", $h.header] + $h.lines)
          else
            (if $h.nc == 0 then $h.ns else $h.ns - 1 end) as $be
            | (if $h.nc == 0 then $h.ns + 1 else $h.ns + $h.nc end) as $as
            | (if $prev == null then 1
               elif $prev.nc == 0 then $prev.ns + 1 else $prev.ns + $prev.nc end) as $floor
            | (if $next == null then $total
               elif $next.nc == 0 then $next.ns else $next.ns - 1 end) as $ceil
            | ([$be - $ctx + 1, $floor] | max) as $bs
            | ([$as + $ctx - 1, $ceil, $total] | min) as $ae
            | ([$be - $bs + 1, 0] | max) as $kb
            | ([$ae - $as + 1, 0] | max) as $ka
            | (if $h.oc == 0 then $h.os else $h.os - 1 end) as $obe
            | ($h.oc + $kb + $ka) as $oc2
            | ($h.nc + $kb + $ka) as $nc2
            | (if $oc2 == 0 then $h.os else $obe - $kb + 1 end) as $os2
            | (if $nc2 == 0 then $h.ns else $be - $kb + 1 end) as $ns2
            | $top
              + (if $prev != null and ($be - $ctx + 1) < $floor then ["(context above stops at hunk " + $prev.id + ")"]
                 elif $bs <= 1 then ["(start of file)"] else [] end)
              + ["@@ -" + ($os2 | tostring) + "," + ($oc2 | tostring)
                 + " +" + ($ns2 | tostring) + "," + ($nc2 | tostring) + " @@"]
              + [ range($bs; $be + 1) as $n | " " + $fl[$n - 1] ]
              + $h.lines
              + [ range($as; $ae + 1) as $n | " " + $fl[$n - 1] ]
              + (if $next != null and ($as + $ctx - 1) > $ceil then ["(context below stops at hunk " + $next.id + ")"]
                 elif $ae >= $total then ["(end of file)"] else [] end)
          end
      end
    | join("\n") | safe
  end
JQ
}

# read_pull DEST ERR REPO N — the PR's own JSON into DEST; exits 3 when there
# is no such PR, 1 when GitHub fails or answers without a head SHA.
read_pull() {
  local dest="$1" err="$2" repo="$3" n="$4" rc=0 nf
  hq_gh "$dest" "$err" api "repos/$repo/pulls/$n" || rc=$?
  if [ "$rc" -eq 124 ]; then
    die_gh "GitHub did not answer within $(hq__gh_timeout)s"
  fi
  if [ "$rc" -ne 0 ]; then
    # A missing repository or PR is a 404: gh exits non-zero, and both its
    # answer and its error line say so. Anything else is a failure.
    nf=$(hq_jq -r 'if (.status // "") == "404" or (.message // "") == "Not Found" then "yes" else "no" end' \
           "$dest" 2>/dev/null || true)
    if [ "$nf" = yes ] || grep -q 'HTTP 404' "$err" 2>/dev/null; then
      die_not_found "no PR $repo#$n"
    fi
    die_gh "GitHub failed: $(hq_gh_first_error "$err")"
  fi
  if ! hq_jq -e '(.head.sha // "") | test("^[0-9a-f]{40}$")' "$dest" >/dev/null 2>&1; then
    die_gh "GitHub returned an unexpected answer for $repo#$n"
  fi
}

main() {
  local repo="" raw_n="" n nodes="" ctx
  local pull files model err empty again head now tries rc=0 line plan id want fid sha
  local blob blob_have blob_why fetched first=1 rendered i found
  local -a cache_fid=() cache_file=() cache_why=()
  local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' num_re='^[1-9][0-9]{0,9}$'
  local node_re='^T?[1-9][0-9]{0,5}(\.[1-9][0-9]{0,5})?$'

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -*) die_usage "unknown option (run pr-outline.sh --help)" ;;
      *)
        if [ -z "$repo" ]; then repo="$1"
        elif [ -z "$raw_n" ]; then raw_n="$1"
        else
          if ! [[ $1 =~ $node_re ]]; then
            die_usage "a node is F, F.H, Tn, or Tn.H (2, 2.3, T1, T1.2), not '$1'"
          fi
          case " $nodes " in
            *" $1 "*) ;;
            *) nodes="$nodes $1" ;;
          esac
        fi
        shift
        ;;
    esac
  done

  if [ -z "$repo" ] || [ -z "$raw_n" ]; then
    die_usage "missing OWNER/REPO or number (run pr-outline.sh --help)"
  fi
  if [ "${#repo}" -gt 200 ] || ! [[ $repo =~ $repo_re ]]; then
    die_usage "the repository must be OWNER/REPO"
  fi
  case "$raw_n" in
    pr-*) n="${raw_n#pr-}" ;;
    issue-*)
      if [[ ${raw_n#issue-} =~ $num_re ]]; then
        die_not_found "$repo#${raw_n#issue-} is an issue: it has no diff to outline"
      fi
      n="$raw_n"
      ;;
    *) n="$raw_n" ;;
  esac
  if ! [[ $n =~ $num_re ]]; then
    die_usage "the number must be a positive whole number or pr-N"
  fi
  ctx="${HQ_OUTLINE_CONTEXT:-20}"
  case "$ctx" in
    ''|*[!0-9]*|0*) die_usage "HQ_OUTLINE_CONTEXT must be a whole number from 1 to 500" ;;
  esac
  if [ "${#ctx}" -gt 3 ] || [ "$ctx" -gt 500 ]; then
    die_usage "HQ_OUTLINE_CONTEXT must be a whole number from 1 to 500"
  fi

  hq_gh_find || die_gh "gh not found (HUMAN_QUEUE_GH, /opt/homebrew/bin/gh, or PATH)"
  hq_jq_find || die_gh "jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  hq_mktemp pull
  hq_mktemp files
  hq_mktemp model
  hq_mktemp err

  read_pull "$pull" "$err" "$repo" "$n"
  head=$(hq_jq -r '.head.sha' "$pull")

  # The file list has no SHA of its own: a push between reading the PR and
  # listing its files would pair the old head with the new diff. So the PR
  # is read again after every listing, and the files are listed again (at
  # most three listings) until the head is the same on both sides of one.
  hq_mktemp again
  tries=0
  while :; do
    tries=$((tries + 1))
    rc=0
    hq_gh "$files" "$err" api --paginate "repos/$repo/pulls/$n/files?per_page=100" || rc=$?
    if [ "$rc" -eq 124 ]; then
      die_gh "GitHub did not list the files within $(hq__gh_timeout)s"
    fi
    if [ "$rc" -ne 0 ]; then
      die_gh "GitHub did not list the files: $(hq_gh_first_error "$err")"
    fi
    read_pull "$again" "$err" "$repo" "$n"
    now=$(hq_jq -r '.head.sha' "$again")
    if [ "$now" = "$head" ]; then
      break
    fi
    if [ "$tries" -ge 3 ]; then
      die_gh "$repo#$n kept being pushed to while it was read (head ${now:0:7}); try again"
    fi
    cat "$again" >"$pull"
    head="$now"
  done

  rc=0
  hq_jq -s --slurpfile pullv "$pull" --arg repo "$repo" --argjson number "$n" \
    "$(model_jq)" "$files" >"$model" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die_gh "could not read GitHub's file list: $(hq_gh_first_error "$err")"
  fi

  if [ -z "$nodes" ]; then
    rc=0
    hq_jq -r "$(lib_jq) $(outline_jq)" "$model" 2>"$err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      die_gh "could not render the outline: $(hq_gh_first_error "$err")"
    fi
    return 0
  fi

  # Every node must exist before anything is printed.
  rc=0
  line=$(hq_jq -r --arg nodes "$nodes" "$(lib_jq) $(check_jq)" "$model" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    die_gh "could not read the outline: $(hq_gh_first_error "$err")"
  fi
  if [ -n "$line" ]; then
    die_not_found "$line"
  fi

  rc=0
  plan=$(hq_jq -r --arg nodes "$nodes" "$(plan_jq)" "$model" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    die_gh "could not read the outline: $(hq_gh_first_error "$err")"
  fi
  hq_mktemp empty
  while IFS=$'\x1f' read -r id want fid sha; do
    [ -n "$id" ] || continue
    blob="$empty"
    blob_have=0
    blob_why="GitHub gave no file at head to read"
    if [ "$want" = fetch ]; then
      # One fetch per file, however many of its hunks are opened.
      i=0
      found=-1
      while [ "$i" -lt "${#cache_fid[@]}" ]; do
        if [ "${cache_fid[$i]}" = "$fid" ]; then found="$i"; break; fi
        i=$((i + 1))
      done
      if [ "$found" -lt 0 ]; then
        hq_mktemp fetched
        rc=0
        hq_gh "$fetched" "$err" api -H "Accept: application/vnd.github.raw" "repos/$repo/git/blobs/$sha" || rc=$?
        found="${#cache_fid[@]}"
        cache_fid[found]="$fid"
        cache_file[found]="$fetched"
        if [ "$rc" -eq 0 ]; then
          cache_why[found]=""
        elif [ "$rc" -eq 124 ]; then
          cache_why[found]="GitHub did not return the file within $(hq__gh_timeout)s"
        else
          cache_why[found]="GitHub did not return the file: $(hq_gh_first_error "$err")"
        fi
      fi
      if [ -z "${cache_why[found]}" ]; then
        blob="${cache_file[found]}"
        blob_have=1
      else
        blob_why="${cache_why[found]}"
      fi
    fi
    rc=0
    rendered=$(hq_jq -r --arg id "$id" --argjson ctx "$ctx" --arg have_blob "$blob_have" \
      --arg why "$blob_why" --rawfile blob "$blob" "$(lib_jq) $(node_jq)" "$model" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      die_gh "could not render $id: $(hq_gh_first_error "$err")"
    fi
    if [ "$first" -eq 0 ]; then printf '\n'; fi
    first=0
    printf '%s\n' "$rendered"
  done <<EOF
$plan
EOF
}

main "$@"
