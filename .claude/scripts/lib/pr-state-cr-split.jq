include "check-run-conclusions";

# Publishing GitHub App, retained on every projected entry (issue #956). The
# preceding dedup step groups by [.app.slug, .app.id, .name] precisely because
# a name is not a publisher. Carry identity on all three arrays so an entry has
# the same shape whichever view a consumer reads; absent app data projects as
# {slug: null, id: null} and the consumer decides whether that fails open or
# closed.
def app_identity:
  {slug: (.app.slug // null), id: (.app.id // null)};

# The retired app is absent from all projected CI views (issue #2192).
map(select(
  ((.app.slug // "") as $slug
   | if $slug == "" then (.name // "") | IN("Graphite / AI Reviews", "Graphite / mergeability_check")
     else $slug | IN("graphite-app", "graphite") end) | not))
| . as $runs
| [$runs[] | select(completed_check | not)] as $incomplete
| [$runs[] | select(completed_check and (.conclusion | optional_check_passes))] as $passing
| [$runs[] | select(completed_check and (.conclusion | optional_check_passes | not))] as $failing
| {
  total: ($runs | length),
  passing: ($passing | length),
  failing: ($failing | length),
  in_progress: ($incomplete | length),
  failing_runs: [$failing[] | {id, name, conclusion, title: .output.title, details_url, html_url, app: app_identity}],
  in_progress_runs: [$incomplete[] | {id, name, status, app: app_identity}],
  all: [.[] | {id, name, status, conclusion, title: .output.title, app: app_identity}]
}
