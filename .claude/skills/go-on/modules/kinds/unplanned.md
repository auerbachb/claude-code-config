<!-- go-on-routing:begin -->
Route `kind:unplanned`.

**Trigger:** 0.4 rank 4, the `unplanned` class.

**Prerequisites:** Step 0 is complete: 0.2a passed, every probe ran, 0.4 selected this class, 0.5 found no matching receipt or `--again` was passed, the lane preflight resolved this module, and the live-work check ran.

**Review modules:** `review:prepare`, `review:publish`, `review:respond`, `review:merge`, in order as the lane reaches them.
<!-- go-on-routing:end -->

- **`unplanned`** — continue to Step 0b. This is the original `/go-on` behavior, unchanged.
