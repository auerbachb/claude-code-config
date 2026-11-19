<!-- go-on-routing:begin -->
Route `kind:planned-stop`.

**Trigger:** 0.4 rank 1, the `pause` or `end` class.

**Prerequisites:** Step 0 is complete: 0.2a passed, every probe ran, 0.4 selected this class, 0.5 found no matching receipt or `--again` was passed, the lane preflight resolved this module, and the live-work check ran.

**Review modules:** none. The delegated command owns the restore.
<!-- go-on-routing:end -->

- **`pause` / `end`** — invoke `/pause-resume` or `/end-resume`, forwarding `--resume-refill` when given, **and, to `/pause-resume` only, `--generation` when 0.2a validated one** (`/end-resume` declares no such flag). Forwarding it is what lets a single re-armed `/go-on` wake serve a day-mode park too: with no per-PR park records the ladder falls here, and `/pause-resume` re-validates the same token against the same field before clearing anything. They clear the execution gate, re-arm stopped work, and own the refill decision. Report their outcome; do not re-run their steps here.
