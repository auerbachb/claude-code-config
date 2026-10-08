# shellcheck shell=bash
# desk/bin/lib/export.sh — the paper copy's renderers (issue #1759): which PDF
# renderer this machine has, and running it under a time bound. Sourced by
# desk/bin/cmd/export.sh after lib/common.sh; never executed. Bash 3.2
# compatible.
#
# RENDERERS, first that produces a PDF:
#   pandoc      the Markdown, when pandoc is installed and it has a PDF engine
#   chrome      the HTML, printed by headless Google Chrome (or Chromium): the
#               footer prints on every page
#   cupsfilter  the plain text, through the macOS print system
#               (/usr/sbin/cupsfilter, text/plain to PDF)
# With none, the caller writes the Markdown instead.
#
# PUBLIC FUNCTIONS
#   hq_export_check_env    exits 4 when HUMAN_QUEUE_EXPORT_RENDERER is not
#                          auto, pandoc, chrome, cupsfilter, or markdown
#   hq_export_pdf VAR MD TXT HTML PDF WORK
#                          writes the PDF from the first renderer that works;
#                          sets VAR to its name and returns 0, or returns 1
#                          (VAR empty) with HQ_EXPORT_TRIED naming what each
#                          one did (`chrome: timed out; cupsfilter: not
#                          installed`). WORK is a private directory for the
#                          renderers' scratch files.
#   hq_export_stop_renderer
#                          stops the renderer hq_export_pdf is waiting on, if
#                          any. For the caller's EXIT trap: an export
#                          interrupted mid-render (SIGTERM, SIGHUP) leaves no
#                          renderer running, where headless Chrome would
#                          otherwise keep running on its own.
#
# ENVIRONMENT
#   HUMAN_QUEUE_EXPORT_RENDERER  auto (default): every renderer in the order
#                                above; pandoc, chrome, or cupsfilter: that one
#                                only; markdown: none (the Markdown is written)
#   HUMAN_QUEUE_PANDOC, HUMAN_QUEUE_CHROME, HUMAN_QUEUE_CUPSFILTER
#                                that renderer's binary. Set to anything that is
#                                not an executable file (empty included), the
#                                renderer counts as not installed. Tests use
#                                these.
#   HUMAN_QUEUE_EXPORT_TIMEOUT   seconds each renderer may take, overriding the
#                                deadlines below (a positive whole number;
#                                anything else keeps them)
#
# Every renderer runs with stdin from /dev/null, without
# HUMAN_QUEUE_DATABASE_URL in its environment, with TMPDIR (and Chrome's
# MAC_CHROMIUM_TMPDIR) inside WORK, so its own temp files go when WORK does,
# and under a deadline (pandoc 120 s, Chrome 60 s, cupsfilter 30 s). Headless
# Chrome can keep running after it has written its PDF, so it is stopped once
# it reports the file written; it runs offline (no host name resolves), so
# it loads the local HTML and nothing else.

HQ_EXPORT_TRIED=""
# The running renderer's pid (hq_export_stop_renderer), and the TMPDIR the
# renderers get (inside WORK; empty: leave TMPDIR as it is).
HQ_EXPORT_PID=""
HQ_EXPORT_RTMP=""

# hq__export_limit DEFAULT — a renderer's deadline in seconds.
hq__export_limit() {
  case "${HUMAN_QUEUE_EXPORT_TIMEOUT:-}" in
    ''|*[!0-9]*|0*) printf '%s' "$1" ;;
    *) printf '%s' "$HUMAN_QUEUE_EXPORT_TIMEOUT" ;;
  esac
}

hq_export_check_env() {
  case "${HUMAN_QUEUE_EXPORT_RENDERER:-auto}" in
    auto|pandoc|chrome|cupsfilter|markdown) ;;
    *) hq_die_validation "export: HUMAN_QUEUE_EXPORT_RENDERER must be auto, pandoc, chrome, cupsfilter, or markdown" ;;
  esac
}

# hq__export_pick VAR OVERRIDE_SET OVERRIDE CANDIDATE... — sets VAR to the
# renderer's binary: OVERRIDE when OVERRIDE_SET is non-empty (the variable is
# set; returns 1 unless it is an executable file), else the first CANDIDATE
# that is an executable file (an absolute path) or a command on PATH (a bare
# name). Returns 1 when none is.
hq__export_pick() {
  local hq__var="$1" hq__isset="$2" hq__over="$3" hq__c hq__p
  shift 3
  printf -v "$hq__var" '%s' ''
  if [ -n "$hq__isset" ]; then
    if [ -n "$hq__over" ] && [ -f "$hq__over" ] && [ -x "$hq__over" ]; then
      printf -v "$hq__var" '%s' "$hq__over"
      return 0
    fi
    return 1
  fi
  for hq__c in "$@"; do
    case "$hq__c" in
      /*)
        if [ -f "$hq__c" ] && [ -x "$hq__c" ]; then
          printf -v "$hq__var" '%s' "$hq__c"
          return 0
        fi
        ;;
      *)
        if hq__p=$(command -v "$hq__c" 2>/dev/null) && [ -n "$hq__p" ] && [ -f "$hq__p" ]; then
          printf -v "$hq__var" '%s' "$hq__p"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# hq__export_stop PID — TERM, up to two seconds to exit, then KILL.
hq__export_stop() {
  local hq__i=0
  kill -TERM "$1" 2>/dev/null || true
  while [ "$hq__i" -lt 10 ] && kill -0 "$1" 2>/dev/null; do
    sleep 0.2
    hq__i=$((hq__i + 1))
  done
  kill -KILL "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# hq__export_run LIMIT DONE OUT ERR CMD... — runs CMD with stdout in the file
# OUT and stderr in the file ERR for at most LIMIT seconds. DONE, when not
# empty, is a fixed string that marks the work done once it appears in ERR:
# CMD is stopped then and the run counts as a success. Returns CMD's status,
# 0 once DONE appeared, or 124 at the deadline (CMD stopped).
hq__export_run() {
  local hq__limit="$1" hq__done="$2" hq__o="$3" hq__e="$4" hq__pid hq__t=0 hq__rc=0
  shift 4
  (
    unset HUMAN_QUEUE_DATABASE_URL
    if [ -n "$HQ_EXPORT_RTMP" ]; then
      exec env TMPDIR="$HQ_EXPORT_RTMP" MAC_CHROMIUM_TMPDIR="$HQ_EXPORT_RTMP" "$@"
    fi
    exec "$@"
  ) </dev/null >"$hq__o" 2>"$hq__e" &
  hq__pid=$!
  HQ_EXPORT_PID="$hq__pid"
  while kill -0 "$hq__pid" 2>/dev/null; do
    if [ -n "$hq__done" ] && grep -qF -- "$hq__done" "$hq__e" 2>/dev/null; then
      hq__export_stop "$hq__pid"
      HQ_EXPORT_PID=""
      return 0
    fi
    if [ "$hq__t" -ge $((hq__limit * 5)) ]; then
      hq__export_stop "$hq__pid"
      HQ_EXPORT_PID=""
      return 124
    fi
    sleep 0.2
    hq__t=$((hq__t + 1))
  done
  # 2>/dev/null: no "Terminated" notice on the caller's stderr.
  wait "$hq__pid" 2>/dev/null || hq__rc=$?
  HQ_EXPORT_PID=""
  return "$hq__rc"
}

hq_export_stop_renderer() {
  if [ -n "$HQ_EXPORT_PID" ]; then
    hq__export_stop "$HQ_EXPORT_PID"
    HQ_EXPORT_PID=""
  fi
}

# hq__export_is_pdf FILE — FILE is non-empty and starts as a PDF does.
hq__export_is_pdf() {
  local hq__head=""
  [ -s "$1" ] || return 1
  hq__head=$(head -c 5 "$1" 2>/dev/null) || return 1
  [ "$hq__head" = "%PDF-" ]
}

# hq__export_note NAME RC PDF — HQ_EXPORT_TRIED gains what NAME did.
hq__export_note() {
  local hq__what
  if [ "$2" -eq 124 ]; then hq__what="timed out"
  elif [ "$2" -ne 0 ]; then hq__what="exit $2"
  else hq__what="no PDF written"
  fi
  HQ_EXPORT_TRIED="$HQ_EXPORT_TRIED${HQ_EXPORT_TRIED:+; }$1: $hq__what"
}

hq__export_missing() {
  HQ_EXPORT_TRIED="$HQ_EXPORT_TRIED${HQ_EXPORT_TRIED:+; }$1: not installed"
}

# hq__export_file_url PATH — a file:// URL for an absolute PATH.
hq__export_file_url() {
  local hq__u="$1"
  # Escaped: a pattern that starts with % or # would anchor to an end.
  hq__u="${hq__u//\%/%25}"
  hq__u="${hq__u// /%20}"
  hq__u="${hq__u//\#/%23}"
  hq__u="${hq__u//\?/%3F}"
  printf 'file://%s' "$hq__u"
}

hq__export_pandoc() {
  local hq__md="$1" hq__pdf="$2" hq__work="$3" hq__bin rc=0
  if ! hq__export_pick hq__bin "${HUMAN_QUEUE_PANDOC+x}" "${HUMAN_QUEUE_PANDOC:-}" \
       /opt/homebrew/bin/pandoc /usr/local/bin/pandoc pandoc; then
    hq__export_missing pandoc
    return 1
  fi
  rm -f "$hq__pdf"
  # The items' text comes from agent threads: export.jq escapes it, so it
  # reads as text. As a second guard the reader takes raw TeX, HTML,
  # attributes, and $math$ as text too (math would reach the PDF engine as
  # TeX), and a YAML block never sets the template's variables.
  hq__export_run "$(hq__export_limit 120)" '' "$hq__work/pandoc.out" "$hq__work/pandoc.err" \
    "$hq__bin" --from markdown-raw_tex-raw_html-raw_attribute-yaml_metadata_block-tex_math_dollars --standalone \
    --output "$hq__pdf" "$hq__md" || rc=$?
  if [ "$rc" -eq 0 ] && hq__export_is_pdf "$hq__pdf"; then return 0; fi
  hq__export_note pandoc "$rc"
  return 1
}

hq__export_chrome() {
  local hq__html="$1" hq__pdf="$2" hq__work="$3" hq__bin rc=0
  if ! hq__export_pick hq__bin "${HUMAN_QUEUE_CHROME+x}" "${HUMAN_QUEUE_CHROME:-}" \
       "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
       "${HOME:-/nonexistent}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
       "/Applications/Chromium.app/Contents/MacOS/Chromium" \
       google-chrome google-chrome-stable chromium chromium-browser; then
    hq__export_missing chrome
    return 1
  fi
  rm -f "$hq__pdf"
  mkdir -p "$hq__work/chrome-profile" || { hq__export_note chrome 1; return 1; }
  # A profile of its own, so a running Chrome is never touched; offline (no
  # host name resolves, and no background fetches), since it needs only the
  # local file; both header flags, for older and newer Chrome (each ignores
  # the one it lacks).
  hq__export_run "$(hq__export_limit 60)" 'bytes written to file' "$hq__work/chrome.out" "$hq__work/chrome.err" \
    "$hq__bin" --headless --disable-gpu --no-first-run --no-default-browser-check \
    --disable-extensions --disable-sync --disable-background-networking \
    '--host-resolver-rules=MAP * ~NOTFOUND' --user-data-dir="$hq__work/chrome-profile" \
    --no-pdf-header-footer --print-to-pdf-no-header --print-to-pdf="$hq__pdf" \
    "$(hq__export_file_url "$hq__html")" || rc=$?
  if [ "$rc" -eq 0 ] && hq__export_is_pdf "$hq__pdf"; then return 0; fi
  hq__export_note chrome "$rc"
  return 1
}

hq__export_cupsfilter() {
  local hq__txt="$1" hq__pdf="$2" hq__work="$3" hq__bin rc=0
  if ! hq__export_pick hq__bin "${HUMAN_QUEUE_CUPSFILTER+x}" "${HUMAN_QUEUE_CUPSFILTER:-}" \
       /usr/sbin/cupsfilter cupsfilter; then
    hq__export_missing cupsfilter
    return 1
  fi
  # The print system wraps at 80 columns mid-word; fold at spaces first.
  fold -s -w 78 "$hq__txt" > "$hq__work/export.folded.txt" 2>/dev/null \
    || cp "$hq__txt" "$hq__work/export.folded.txt"
  hq__export_run "$(hq__export_limit 30)" '' "$hq__pdf" "$hq__work/cupsfilter.err" \
    "$hq__bin" -m application/pdf -i text/plain "$hq__work/export.folded.txt" || rc=$?
  if [ "$rc" -eq 0 ] && hq__export_is_pdf "$hq__pdf"; then return 0; fi
  hq__export_note cupsfilter "$rc"
  return 1
}

hq_export_pdf() {
  local hq__var="$1" hq__md="$2" hq__txt="$3" hq__html="$4" hq__pdf="$5" hq__work="$6" hq__r hq__list
  case "$hq__var" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*|hq__*) hq_die_error "hq_export_pdf: invalid variable name '$hq__var'" ;;
  esac
  printf -v "$hq__var" '%s' ''
  HQ_EXPORT_TRIED=""
  HQ_EXPORT_RTMP="$hq__work/tmp"
  mkdir -p "$HQ_EXPORT_RTMP" 2>/dev/null || HQ_EXPORT_RTMP=""
  case "${HUMAN_QUEUE_EXPORT_RENDERER:-auto}" in
    auto) hq__list="pandoc chrome cupsfilter" ;;
    markdown) HQ_EXPORT_TRIED="HUMAN_QUEUE_EXPORT_RENDERER=markdown"; return 1 ;;
    *) hq__list="$HUMAN_QUEUE_EXPORT_RENDERER" ;;
  esac
  for hq__r in $hq__list; do
    case "$hq__r" in
      pandoc) hq__export_pandoc "$hq__md" "$hq__pdf" "$hq__work" || continue ;;
      chrome) hq__export_chrome "$hq__html" "$hq__pdf" "$hq__work" || continue ;;
      cupsfilter) hq__export_cupsfilter "$hq__txt" "$hq__pdf" "$hq__work" || continue ;;
      *) continue ;;
    esac
    printf -v "$hq__var" '%s' "$hq__r"
    return 0
  done
  return 1
}
