# Shared list-marker alternation for POSIX ERE and Python re consumers.
# Keep this group-free so each caller controls its own capture groups.
# CommonMark ordered markers contain one to nine digits, followed by . or ).
AC_LIST_MARKER_RE='[-*+]|[0-9]{1,9}[.)]'
