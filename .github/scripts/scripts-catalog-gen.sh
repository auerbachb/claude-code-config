#!/usr/bin/env bash
# Generate the .claude/scripts/ catalog from the directory contents (issue #1578).
#
# WHY THIS EXISTS
#
# Issue #898 split the per-script catalog out of one shared README into an index
# plus one doc per category, and scripts-catalog-lint.sh made the split
# authoritative: every script and test needed a hand-written row or CI failed.
# That trade bought accuracy and paid for it in churn — every script added or
# renamed forced an edit to a shared markdown file, which is churn no refactor
# can retire (issue #1571 had to exempt two of those files from hotspot
# scoring) and a recurring merge-conflict surface for concurrent PRs (PR #1543,
# 2026-09-01).
#
# The fix is to move the one thing a human must write — the description — into
# the file it describes, and to derive everything else. Adding a script is then
# a single-file change plus a generator run, and a region two PRs both touched
# is resolved by re-running the generator rather than by reading a diff.
#
# WHAT IS GENERATED
#
#   .claude/scripts/docs/<id>.md   the row table(s) between
#                                  <!-- catalog:rows:begin [kind=sh|py] --> and
#                                  <!-- catalog:rows:end -->
#   .claude/scripts/README.md      the Categories table between
#                                  <!-- catalog:categories:begin --> and
#                                  <!-- catalog:categories:end -->
#   .claude/reference/churn-hotspot-exemptions.json
#                                  one exemption entry per catalog file that
#                                  carries a generated region, each stamped
#                                  "generated_by". Entries WITHOUT that stamp
#                                  are hand-written and are preserved verbatim.
#
# Everything outside those regions — prose, table headers, the `## Python
# helpers` subsection, back-links, the exemption file's `source` block — is
# human-edited and never touched.
#
# WHAT A HUMAN WRITES
#
#   In each in-scope file, one header line:
#       # catalog: <category-id> — <one-line description>
#   In each category doc, its own identity:
#       <!-- catalog:category id=<id> order=<N> -->
#       <!-- catalog:covers <one-line summary for the index> -->
#   The doc's H1 supplies the category title.
#
# So adding a category means adding a doc, and adding a script means editing
# that script. Neither requires an edit to a file someone else is also editing.
#
# ROW ORDER is LC_ALL=C by link text, tie-broken by path, for every doc.
# This deliberately supersedes issue #1544's per-doc `<!-- catalog-lint:
# ordered -->` opt-in and the workflow-role grouping the other docs used:
# mechanical order is what makes a region two branches both regenerated
# resolvable by re-running this script, which is half of what issue #1578 is
# for. Rationale: .claude/reference/scripts-catalog-generation-decision.md.
#
# Usage:
#   .github/scripts/scripts-catalog-gen.sh --check   verify committed == generated
#   .github/scripts/scripts-catalog-gen.sh --write   rewrite the generated regions
#
# Run from the repo root (or pass --root). Exits 0 clean, 1 on drift or a
# malformed declaration, 2 on a usage error.

set -euo pipefail
shopt -s nullglob

errors=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lint-common.sh
source "$SCRIPT_DIR/lib/lint-common.sh"

MODE=""
want=""
ROOT="."
GEN_STAMP=".github/scripts/scripts-catalog-gen.sh"
ENFORCING_LINT=".github/scripts/scripts-catalog-lint.sh (run via .github/scripts/run-doc-lints.sh in .github/workflows/rule-lint.yml)"

usage() {
  cat <<'EOF'
Usage: .github/scripts/scripts-catalog-gen.sh (--check | --write) [--root DIR]

  Generates the .claude/scripts/ catalog rows, the index Categories table, and
  the catalog entries in .claude/reference/churn-hotspot-exemptions.json from
  the directory contents and each file's `# catalog:` header line.

  --check   Regenerate into a temp buffer and diff against the committed files.
            Exits 1 on drift, naming each stale file.
  --write   Rewrite the generated regions in place.
  --root D  Treat D as the repo root (default: the current directory).
  --help    Show this message.

Exit codes:
  0  clean (--check) or written (--write)
  1  drift, or a malformed/missing `# catalog:` declaration
  2  usage error
EOF
}

while (( $# > 0 )); do
  case "$1" in
    # Repeating the same mode is harmless; asking for both is a contradiction,
    # and letting the last one win would silently WRITE for a caller who asked
    # to check — the one direction that must never happen by accident.
    --check|--write)
      want="${1#--}"
      if [[ -n "$MODE" && "$MODE" != "$want" ]]; then
        echo "::error::--check and --write are mutually exclusive"
        usage >&2
        exit 2
      fi
      MODE="$want"
      ;;
    --root)
      shift
      (( $# > 0 )) || { echo "::error::--root requires a value"; exit 2; }
      ROOT="$1"
      ;;
    --root=*)
      ROOT="${1#*=}"
      [[ -n "$ROOT" ]] || { echo "::error::--root requires a non-empty value"; exit 2; }
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "::error::Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$MODE" ]]; then
  echo "::error::exactly one of --check or --write is required"
  usage >&2
  exit 2
fi

ROOT="${ROOT%/}"
[[ -n "$ROOT" ]] || ROOT="/"

INDEX_REL=".claude/scripts/README.md"
EXEMPTIONS_REL=".claude/reference/churn-hotspot-exemptions.json"
DOCS_ABS="$ROOT/$CATALOG_DOCS_DIR"
INDEX_ABS="$ROOT/$INDEX_REL"
EXEMPTIONS_ABS="$ROOT/$EXEMPTIONS_REL"

if [[ ! -d "$DOCS_ABS" ]]; then
  echo "::error::${CATALOG_DOCS_DIR} directory not found under ${ROOT}"
  exit 1
fi
if [[ ! -f "$INDEX_ABS" ]]; then
  echo "::error file=${INDEX_REL}::index not found"
  exit 1
fi

TMPDIR_GEN=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_GEN"; }
trap cleanup EXIT

# --- read every category doc's declaration --------------------------------
# id<US>order<US>title<US>covers<US>doc-relative-path, one per doc.
read_declaration() {
  awk '
    function trim(s) { gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*(```|~~~)/ {
      fence_tok = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
      if (!in_fence) { in_fence = 1; fence = fence_tok }
      else if (fence_tok == fence) { in_fence = 0; fence = "" }
      next
    }
    in_fence { next }
    /^[[:space:]]*<!--[[:space:]]*catalog:category[[:space:]]/ {
      line = $0
      if (match(line, /id=[A-Za-z0-9][A-Za-z0-9_-]*/)) id = substr(line, RSTART + 3, RLENGTH - 3)
      if (match(line, /order=[0-9]+/)) order = substr(line, RSTART + 6, RLENGTH - 6)
      next
    }
    /^[[:space:]]*<!--[[:space:]]*catalog:covers[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]*<!--[[:space:]]*catalog:covers[[:space:]]*/, "", line)
      sub(/[[:space:]]*-->[[:space:]]*$/, "", line)
      covers = trim(line)
      next
    }
    title == "" && /^#[[:space:]]/ {
      line = $0
      sub(/^#[[:space:]]*/, "", line)
      title = trim(line)
      next
    }
    END { printf "%s\037%s\037%s\037%s\n", id, order, title, covers }
  ' "$1"
}

declarations=""
for doc in "$DOCS_ABS"/*.md; do
  rel="${doc#"$ROOT/"}"
  decl=$(read_declaration "$doc")
  IFS=$'\037' read -r d_id d_order d_title d_covers <<< "$decl"
  if [[ -z "$d_id" ]]; then
    echo "::error file=${rel}::no <!-- catalog:category id=... order=... --> declaration"
    errors=$((errors + 1))
    continue
  fi
  if [[ -z "$d_order" ]]; then
    echo "::error file=${rel}::catalog:category declaration has no order=<N>"
    errors=$((errors + 1))
    continue
  fi
  if [[ -z "$d_title" ]]; then
    echo "::error file=${rel}::no H1 heading to use as the category title"
    errors=$((errors + 1))
    continue
  fi
  if [[ -z "$d_covers" ]]; then
    echo "::error file=${rel}::no <!-- catalog:covers ... --> summary for the index"
    errors=$((errors + 1))
    continue
  fi
  if [[ "$d_id" != "$(basename "$rel" .md)" ]]; then
    echo "::error file=${rel}::declares id '${d_id}' but the file is named '$(basename "$rel")' — the id must be the filename stem"
    errors=$((errors + 1))
    continue
  fi
  declarations+="${d_id}"$'\037'"${d_order}"$'\037'"${d_title}"$'\037'"${d_covers}"$'\037'"${rel}"$'\n'
done

if [[ -z "$declarations" ]]; then
  echo "::error::${CATALOG_DOCS_DIR}/ declares no categories — the catalog is empty"
  exit 1
fi

# Duplicate ids would make "which doc owns this script" ambiguous, and the
# generator would write the same rows into two files.
dupe_ids=$(printf '%s' "$declarations" | cut -d$'\037' -f1 | LC_ALL=C sort | uniq -d)
if [[ -n "$dupe_ids" ]]; then
  while IFS= read -r dupe; do
    [[ -z "$dupe" ]] && continue
    echo "::error::category id '${dupe}' is declared by more than one doc under ${CATALOG_DOCS_DIR}/"
    errors=$((errors + 1))
  done <<< "$dupe_ids"
fi

# --- read every in-scope file's declaration -------------------------------
if ! inscope=$(catalog_inscope_files "$ROOT"); then
  echo "::error::No scripts found under ${CATALOG_SCRIPTS_DIR}/ — the inventory glob is broken"
  exit 1
fi

# path<US>id<US>kind<US>description
entries=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  meta=$(catalog_meta "$ROOT/$rel") && meta_rc=0 || meta_rc=$?
  if (( meta_rc == 1 )); then
    echo "::error file=${rel}::no '# catalog: <category-id> — <description>' line in the header"
    errors=$((errors + 1))
    continue
  fi
  if (( meta_rc == 2 )); then
    echo "::error file=${rel}::malformed '# catalog:' line — expected '# catalog: <category-id> — <description>'"
    errors=$((errors + 1))
    continue
  fi
  if (( meta_rc != 0 )); then
    echo "::error file=${rel}::could not be read while looking for its '# catalog:' declaration"
    errors=$((errors + 1))
    continue
  fi
  IFS=$'\037' read -r e_id e_desc <<< "$meta"
  if ! grep -qxF "$e_id" <<<"$(cut -d$'\037' -f1 <<<"$declarations")"; then
    echo "::error file=${rel}::category id '${e_id}' does not match any doc under ${CATALOG_DOCS_DIR}/"
    errors=$((errors + 1))
    continue
  fi
  case "$rel" in
    *.py) e_kind="py" ;;
    *)    e_kind="sh" ;;
  esac
  entries+="${rel}"$'\037'"${e_id}"$'\037'"${e_kind}"$'\037'"${e_desc}"$'\n'
done <<< "$inscope"

if (( errors > 0 )); then
  echo "scripts-catalog-gen: ${errors} error(s) found"
  exit 1
fi

# --- build the generated blocks -------------------------------------------
# One block per (category id, kind), rows LC_ALL=C by link text and tie-broken
# by path — the tie is the top-level/tests/ namesake pair of issue #1452, which
# renders identically and so has no visible order of its own.
rows_block() {
  local want_id="$1" want_kind="$2"
  printf '%s' "$entries" \
    | while IFS=$'\037' read -r r_path r_id r_kind r_desc; do
        [[ "$r_id" == "$want_id" && "$r_kind" == "$want_kind" ]] || continue
        printf '%s\037%s\037%s\n' "${r_path##*/}" "$r_path" "$r_desc"
      done \
    | LC_ALL=C sort -t$'\037' -k1,1 -k2,2 \
    | while IFS=$'\037' read -r s_name s_path s_desc; do
        catalog_row "$s_path" "$s_desc"
      done
}

categories_block() {
  printf '%s' "$declarations" \
    | LC_ALL=C sort -t$'\037' -k2,2n -k1,1 \
    | while IFS=$'\037' read -r c_id c_order c_title c_covers c_rel; do
        # BOTH cells are escaped. The title is a doc's H1, taken verbatim, so a
        # pipe in it would split the row and silently corrupt the index table —
        # and the corruption regenerates identically, so --check could not see it.
        printf '| [%s](%s) | %s |\n' "${c_title//|/\\|}" "docs/${c_id}.md" "${c_covers//|/\\|}"
      done
}

# render_rows FILE BLOCK_DIR
# Rewrites every <!-- catalog:rows:begin [kind=K] --> ... <!-- catalog:rows:end -->
# region in FILE with the contents of BLOCK_DIR/rows.K, and prints the result.
# A doc may carry any number of regions (utilities.md carries a sh one and a py
# one), so this is a single pass over the whole file rather than one pass per
# kind: a per-kind pass would meet the OTHER kind's end marker with no begin and
# have to guess whether that was corruption.
#
# Exits 3 on a region that never opens, never closes, nests, or names a kind
# with no block — a doc that silently lost its markers must never be reported as
# up to date. Exits 4 when the file carries no region at all.
render_rows() {
  local file="$1" block_dir="$2"
  awk -v block_dir="$block_dir" '
    # Fence tracking comes first, and markers are only honoured OUTSIDE a fence:
    # a doc that shows the marker syntax in a fenced example must not have that
    # example rewritten as a real region. The catalog lint applies the same fence
    # rule when it looks for stray rows, and the two have to agree — a marker one
    # side treats as real and the other as an example is a doc neither checks.
    # Fence state is only updated outside a region, because a region holds
    # generated rows and never a fence.
    !inside && /^[[:space:]]*(```|~~~)/ {
      fence_tok = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
      if (!in_fence) { in_fence = 1; fence = fence_tok }
      else if (fence_tok == fence) { in_fence = 0; fence = "" }
      print
      next
    }
    !in_fence && /<!--[[:space:]]*catalog:rows:begin/ {
      if (inside) { bad = 3; exit }
      kind = "sh"
      if (match($0, /kind=[A-Za-z]+/)) kind = substr($0, RSTART + 5, RLENGTH - 5)
      blockfile = block_dir "/rows." kind
      if ((getline probe < blockfile) < 0) { bad = 3; exit }
      close(blockfile)
      print
      inside = 1
      seen = 1
      while ((getline line < blockfile) > 0) print line
      close(blockfile)
      next
    }
    !in_fence && /<!--[[:space:]]*catalog:rows:end/ {
      if (!inside) { bad = 3; exit }
      inside = 0
      print
      next
    }
    inside { next }
    { print }
    END {
      if (bad) exit bad
      if (inside) exit 3
      if (!seen) exit 4
    }
  ' "$file"
}

# render_categories FILE BLOCK_FILE — same contract for the index table.
render_categories() {
  local file="$1" block="$2"
  awk -v block="$block" '
    !inside && /^[[:space:]]*(```|~~~)/ {
      fence_tok = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
      if (!in_fence) { in_fence = 1; fence = fence_tok }
      else if (fence_tok == fence) { in_fence = 0; fence = "" }
      print
      next
    }
    !in_fence && /<!--[[:space:]]*catalog:categories:begin/ {
      if (inside) { bad = 3; exit }
      print
      inside = 1
      seen = 1
      while ((getline line < block) > 0) print line
      close(block)
      next
    }
    !in_fence && /<!--[[:space:]]*catalog:categories:end/ {
      if (!inside) { bad = 3; exit }
      inside = 0
      print
      next
    }
    inside { next }
    { print }
    END {
      if (bad) exit bad
      if (inside) exit 3
      if (!seen) exit 4
    }
  ' "$file"
}

# Which kinds a doc actually holds a region for. Reported so a file whose
# category names a doc with no region for its kind surfaces as unplaced below,
# rather than being silently dropped from the catalog.
region_kinds() {
  awk '
    /^[[:space:]]*(```|~~~)/ {
      fence_tok = ($0 ~ /^[[:space:]]*```/) ? "```" : "~~~"
      if (!in_fence) { in_fence = 1; fence = fence_tok }
      else if (fence_tok == fence) { in_fence = 0; fence = "" }
      next
    }
    in_fence { next }
    /<!--[[:space:]]*catalog:rows:begin/ {
      kind = "sh"
      if (match($0, /kind=[A-Za-z]+/)) kind = substr($0, RSTART + 5, RLENGTH - 5)
      print kind
    }
  ' "$1"
}

PLACED="$TMPDIR_GEN/placed"
: > "$PLACED"

# --- generate each category doc -------------------------------------------
GEN_DIR="$TMPDIR_GEN/gen"
mkdir -p "$GEN_DIR"
managed=""   # rel<US>generated-file

while IFS=$'\037' read -r c_id c_order c_title c_covers c_rel; do
  [[ -z "$c_id" ]] && continue
  doc_abs="$ROOT/$c_rel"
  kinds=$(region_kinds "$doc_abs")
  if [[ -z "$kinds" ]]; then
    echo "::error file=${c_rel}::no <!-- catalog:rows:begin --> / <!-- catalog:rows:end --> region"
    errors=$((errors + 1))
    continue
  fi
  # Two regions of the same kind in one doc would each be filled with the SAME
  # rows block, listing every script twice — and `--check` would not see it,
  # because regeneration reproduces the duplication byte for byte. A guard that
  # cannot detect the drift it exists to detect has to refuse the input instead.
  dup_kinds=$(printf '%s\n' "$kinds" | LC_ALL=C sort | uniq -d)
  if [[ -n "$dup_kinds" ]]; then
    while IFS= read -r dk; do
      [[ -z "$dk" ]] && continue
      echo "::error file=${c_rel}::more than one <!-- catalog:rows:begin kind=${dk} --> region — each kind may appear at most once per doc, or every row would be emitted into both"
      errors=$((errors + 1))
    done <<< "$dup_kinds"
    continue
  fi
  block_dir="$TMPDIR_GEN/blocks/$c_id"
  mkdir -p "$block_dir"
  while IFS= read -r kind; do
    [[ -z "$kind" ]] && continue
    rows_block "$c_id" "$kind" > "$block_dir/rows.$kind"
    # `|| continue` rather than a trailing `&&`: the loop's exit status is its
    # last body command's, so a final non-matching row would make the whole
    # pipeline return 1 and `set -e` would kill the run with no diagnostic.
    printf '%s' "$entries" \
      | while IFS=$'\037' read -r r_path r_id r_kind r_desc; do
          [[ "$r_id" == "$c_id" && "$r_kind" == "$kind" ]] || continue
          printf '%s\n' "$r_path"
        done >> "$PLACED"
  done <<< "$kinds"
  out="$GEN_DIR/$(printf '%s' "$c_rel" | tr '/' '_')"
  if ! render_rows "$doc_abs" "$block_dir" > "$out"; then
    echo "::error file=${c_rel}::catalog:rows region is unbalanced, nested, or names a kind with no rows block"
    errors=$((errors + 1))
    continue
  fi
  managed+="${c_rel}"$'\037'"${out}"$'\n'
done <<< "$declarations"

# Every in-scope file must land in exactly one region. A .py file whose category
# doc carries no kind=py region is the shape this catches: its declaration is
# valid, its doc exists, and without this check its row would simply vanish.
unplaced=$(comm -23 \
  <(printf '%s' "$entries" | cut -d$'\037' -f1 | LC_ALL=C sort) \
  <(LC_ALL=C sort -u "$PLACED") || true)
if [[ -n "$unplaced" ]]; then
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    echo "::error file=${u}::no catalog row region accepts this file — its category doc has no matching kind region"
    errors=$((errors + 1))
  done <<< "$unplaced"
fi

# --- generate the index Categories table ----------------------------------
cat_block="$TMPDIR_GEN/categories"
categories_block > "$cat_block"
index_out="$GEN_DIR/index_README.md"
if ! render_categories "$INDEX_ABS" "$cat_block" > "$index_out"; then
  echo "::error file=${INDEX_REL}::catalog:categories region is missing or unbalanced"
  errors=$((errors + 1))
else
  managed+="${INDEX_REL}"$'\037'"${index_out}"$'\n'
fi

# --- generate the churn-hotspot exemption entries -------------------------
# Every catalog file this script owns a region in churns on a schedule no
# refactor can change: a script added, renamed, or recategorised rewrites a row
# here and CI fails without it. That is precisely the condition issue #1571's
# exemption mechanism exists for, so the entries are derived from the same
# directory contents as the rows rather than hand-maintained — the list cannot
# fall behind the docs it describes.
#
# Hand-written entries (no "generated_by") are preserved untouched: this owns
# the catalog's entries, not the file.
exemption_reason() {
  local rel="$1"
  if [[ "$rel" == "$INDEX_REL" ]]; then
    printf '%s' "The scripts catalog index. Its Categories table is a generated region owned by ${GEN_STAMP}, and the catalog lint fails CI when the committed region drifts from the directory contents, so adding or renaming a category doc forces an edit here. Structural churn, not a refactor signal (issues #898, #1571, #1578)."
  else
    printf '%s' "Category doc '$(basename "$rel" .md)'. Its row table is a generated region owned by ${GEN_STAMP}, and the catalog lint fails CI when the committed region drifts from the directory contents, so every script or test added, renamed, or recategorised forces a row edit here (issues #1571, #1578)."
  fi
}

exemptions_out="$GEN_DIR/exemptions.json"
if [[ ! -f "$EXEMPTIONS_ABS" ]]; then
  echo "::error file=${EXEMPTIONS_REL}::exemption file not found"
  errors=$((errors + 1))
elif ! jq -e 'type == "object" and ((.exemptions | type) == "object")' \
       "$EXEMPTIONS_ABS" >/dev/null 2>&1; then
  # Validated before the first query, so a malformed file fails on its own terms
  # with this script's documented exit 1. Without it, `set -e` kills the run on
  # jq's raw parse error and the caller gets neither the annotation nor the
  # status the --help contract promises.
  echo "::error file=${EXEMPTIONS_REL}::not a JSON object carrying an \"exemptions\" object — cannot sync the catalog exemption entries"
  errors=$((errors + 1))
else
  gen_entries="$TMPDIR_GEN/gen-exemptions.json"
  TODAY="${CATALOG_GEN_TODAY:-$(date -u +%Y-%m-%d)}"
  printf '{}' > "$gen_entries"
  while IFS=$'\037' read -r m_rel m_out; do
    [[ -z "$m_rel" ]] && continue
    prev_as_of=$(jq -r --arg k "$m_rel" '.exemptions[$k].as_of // empty' "$EXEMPTIONS_ABS")
    [[ -n "$prev_as_of" ]] || prev_as_of="$TODAY"
    jq --arg k "$m_rel" --arg lint "$ENFORCING_LINT" \
       --arg reason "$(exemption_reason "$m_rel")" \
       --arg gen "$GEN_STAMP" --arg as_of "$prev_as_of" \
       '. + {($k): {lint: $lint, reason: $reason, generated_by: $gen, as_of: $as_of}}' \
       "$gen_entries" > "$gen_entries.next"
    mv "$gen_entries.next" "$gen_entries"
  done <<< "$managed"

  jq --slurpfile gen "$gen_entries" --arg gen_stamp "$GEN_STAMP" '
    .exemptions = (
      ( [ .exemptions | to_entries[] | select((.value.generated_by // "") != $gen_stamp) ]
        + ( $gen[0] | to_entries ) )
      | sort_by(.key) | from_entries
    )
  ' "$EXEMPTIONS_ABS" > "$exemptions_out"
  managed+="${EXEMPTIONS_REL}"$'\037'"${exemptions_out}"$'\n'
fi

if (( errors > 0 )); then
  echo "scripts-catalog-gen: ${errors} error(s) found"
  exit 1
fi

# --- apply or verify -------------------------------------------------------
drift=0
while IFS=$'\037' read -r m_rel m_out; do
  [[ -z "$m_rel" ]] && continue
  if [[ "$MODE" == "write" ]]; then
    if ! cmp -s "$ROOT/$m_rel" "$m_out"; then
      cp "$m_out" "$ROOT/$m_rel"
      echo "scripts-catalog-gen: wrote ${m_rel}"
    fi
  else
    if ! cmp -s "$ROOT/$m_rel" "$m_out"; then
      echo "::error file=${m_rel}::committed catalog region is stale — run '.github/scripts/scripts-catalog-gen.sh --write'"
      diff -u "$ROOT/$m_rel" "$m_out" | sed -n '1,40p' >&2 || true
      drift=$((drift + 1))
    fi
  fi
done <<< "$managed"

if (( drift > 0 )); then
  echo "scripts-catalog-gen: ${drift} file(s) out of date"
  exit 1
fi

entry_count=$(printf '%s' "$entries" | grep -c . || true)
doc_count=$(printf '%s' "$declarations" | grep -c . || true)
if [[ "$MODE" == "write" ]]; then
  echo "scripts-catalog-gen: OK (${entry_count} entries across ${doc_count} category docs)"
else
  echo "scripts-catalog-gen: OK (${entry_count} entries across ${doc_count} category docs, no drift)"
fi
