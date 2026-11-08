# Shared list-marker alternation for POSIX ERE and Python re consumers.
# Keep this group-free so each caller controls its own capture groups.
# CommonMark ordered markers contain one to nine digits, followed by . or ).
AC_LIST_MARKER_RE='[-*+]|[0-9]{1,9}[.)]'
AC_FENCE_RE='^ {0,3}(`{3,}|~{3,})(.*)$'
AC_FENCE_CHAR=""
AC_FENCE_LENGTH=0

# Return success for fence boundaries and contents, without inspecting them as
# criteria. Root fences follow CommonMark 4.5: same kind, long-enough closing
# run and whitespace-only closer; a backtick info string cannot contain `.
ac_skip_fenced_line() {
  local ac__line="$1" ac__mark ac__rest
  if [[ -n "$AC_FENCE_CHAR" ]]; then
    if [[ "$ac__line" =~ $AC_FENCE_RE ]]; then
      ac__mark="${BASH_REMATCH[1]}"; ac__rest="${BASH_REMATCH[2]}"
      ac__rest="${ac__rest// /}"; ac__rest="${ac__rest//$'\t'/}"
      if [[ "${ac__mark:0:1}" == "$AC_FENCE_CHAR" && "${#ac__mark}" -ge "$AC_FENCE_LENGTH" && -z "$ac__rest" ]]; then
        AC_FENCE_CHAR=""; AC_FENCE_LENGTH=0
      fi
    fi
    return 0
  fi
  if [[ "$ac__line" =~ $AC_FENCE_RE ]]; then
    ac__mark="${BASH_REMATCH[1]}"; ac__rest="${BASH_REMATCH[2]}"
    if [[ "${ac__mark:0:1}" == '`' && "$ac__rest" == *'`'* ]]; then return 1; fi
    AC_FENCE_CHAR="${ac__mark:0:1}"; AC_FENCE_LENGTH=${#ac__mark}
    return 0
  fi
  return 1
}
