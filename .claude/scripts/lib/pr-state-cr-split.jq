def is_blocking:
  . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
def is_passing:
  . == "success" or . == "neutral" or . == "skipped" or . == "cancelled";

# Publishing GitHub App, retained on every projected entry (issue #956). The
# preceding dedup step groups by [.app.slug, .app.id, .name] precisely because
# a name is not a publisher. Carry identity on all three arrays so an entry has
# the same shape whichever view a consumer reads; absent app data projects as
# {slug: null, id: null} and the consumer decides whether that fails open or
# closed.
def app_identity:
  {slug: (.app.slug // null), id: (.app.id // null)};

{
  total: length,
  passing: ([.[] | select(.conclusion | is_passing)] | length),
  failing: ([.[] | select(.conclusion | is_blocking)] | length),
  in_progress: ([.[] | select(.status != "completed")] | length),
  failing_runs: [.[] | select(.conclusion | is_blocking) | {id, name, conclusion, title: .output.title, details_url, html_url, app: app_identity}],
  in_progress_runs: [.[] | select(.status != "completed") | {id, name, status, app: app_identity}],
  all: [.[] | {id, name, status, conclusion, title: .output.title, app: app_identity}]
}
