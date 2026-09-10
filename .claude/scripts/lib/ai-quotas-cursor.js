#!/usr/bin/env node
// ai-quotas-cursor.js — read one Cursor account's two monthly dollar pools
// through a saved browser session (issue #1668).
//
// WHY A BROWSER AT ALL
//   Cursor exposes no individual usage API: the Admin and Analytics APIs are
//   Enterprise-only, and the legacy token call returns request counts from a
//   pricing model Ultra no longer uses. The only reliable source for the two
//   monthly pools is the logged-in dashboard, so this helper drives the
//   dashboard the same way a person does and reads the response the page's
//   own JavaScript asks for.
//
// THE ENDPOINT WAS CAPTURED, NOT GUESSED
//   Recorded from the Spending tab's network activity on 2026-09-08 (a live
//   Ultra account). Loading https://cursor.com/dashboard/spending issues:
//     POST /api/dashboard/get-current-period-usage   <- the two pools
//     POST /api/dashboard/get-plan-info              <- plan name, price
//     POST /api/dashboard/get-monthly-billing-cycle  <- cycle bounds
//     POST /api/dashboard/get-credit-grants-balance
//     POST /api/dashboard/get-client-visible-credit-grants
//     POST /api/dashboard/get-sand-usage-status
//   All are POSTs with a `{}` body; the session cookie is the only auth. The
//   first is the one this reader needs; response fields and the reason
//   `used_usd` comes back null are in .claude/reference/ai-quotas.md.
//
// NO COOKIE OR SESSION VALUE EVER LEAVES THE PROFILE DIRECTORY. The session
// lives inside the persistent user-data dir and is used in place by the
// browser. This helper serialises a fixed set of NUMERIC fields plus the
// payload's top-level key names — never a header, never a cookie, never a
// response body verbatim.
//
// USAGE
//   node ai-quotas-cursor.js --profile-dir <dir> [--mode read|login]
//                            [--timeout-ms <n>] [--url <u>] [--endpoint <path>]
//   node ai-quotas-cursor.js --help
//
//   --mode read   (default) headless run against the saved session.
//   --mode login  headed run: a person logs in, and the helper waits until
//                 the usage endpoint answers before returning.
//
// OUTPUT
//   Exactly one JSON object on stdout, always, for every outcome this helper
//   models — a verdict, never a crash. stderr carries nothing the caller
//   parses. Exit 0 whenever a verdict was printed; exit 2 only for a usage
//   error, where no verdict exists to print.
//
//   { "status": "ok", "source": "network"|"fetch", "endpoint": "<url>",
//     "billing_cycle_end_epoch": <int seconds>,
//     "billing_cycle_start_epoch": <int seconds>,
//     "pools": [ { "pool": "cursor-models", "used_pct": <number> },
//                { "pool": "other-models",  "used_pct": <number> } ],
//     "plan_used_usd": <number|null>, "plan_included_usd": <number|null>,
//     "spend_limit_used_usd": <number|null>,
//     "spend_limit_usd": <number|null>,
//     "plan_name": <string|null> }
//
//   `spend_limit_used_usd` / `spend_limit_usd` are the on-demand block
//   (`spendLimitUsage.individualUsed` of `.individualLimit`, cents): what has
//   already been spent past the included usage, and the ceiling set for it.
//   #1669's overage column renders them.
//
//   { "status": "needs-login", "detail": "…" }        session missing/expired
//   { "status": "unreadable",  "detail": "…",
//     "keys_seen": ["…"] }                            response shape changed
//   { "status": "unreachable", "detail": "…" }        driver/browser/network
//
//   `unreadable` NEVER carries a figure. A pool percentage this helper could
//   not read is an absent field, not a 0 — a zero would render as "plenty
//   left", which is the opposite of "we do not know".
//
// DEPENDENCY
//   playwright, pinned in the sibling package.json. Install it (and the
//   browser binary) once:
//     npm install --prefix .claude/scripts/lib
//     npx --prefix .claude/scripts/lib playwright install chromium
//   With playwright absent this helper reports `unreachable` naming that
//   command rather than throwing — a missing driver must read as "no figure",
//   never as an account problem.
//
//   Playwright 1.63 requires Node >= 20 (its own `engines` field); the pin and
//   that floor are declared together in package.json.

'use strict';

const DEFAULT_URL = 'https://cursor.com/dashboard/spending';
// Matched against the URL's PATH ONLY, and EXACTLY — so a query string does
// not stop it matching, while no other path matches by accident: not a longer
// one (`…-v2`) and not a prefixed one (`/debug/api/dashboard/get-current-
// period-usage`), either of which a suffix test would accept. A substring test
// over the whole URL would be looser still. See pathIs().
const DEFAULT_ENDPOINT = '/api/dashboard/get-current-period-usage';
const PLAN_ENDPOINT = '/api/dashboard/get-plan-info';
// Landing on any of these means the saved session is gone, and there is no
// point waiting out the read bound for a response that will never come.
const LOGIN_URL_MARKERS = ['/login', '/sign-in', '/signin', '/authenticate', 'authkit', 'auth0'];

const DEFAULT_READ_TIMEOUT_MS = 20000;
const DEFAULT_LOGIN_TIMEOUT_MS = 300000;
// An upper bound on --timeout-ms, not a style preference. `[1-9][0-9]*`
// accepts a digit string of any length, and Number() turns a long enough one
// into Infinity — a "bound" no wait can ever reach, i.e. the unbounded run
// this helper's bound exists to prevent, arriving through the argument that
// was supposed to shorten it. A day is far past any legitimate value here.
const MAX_TIMEOUT_MS = 86400000;

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

// Thrown rather than exited: `process.exit()` discards anything still buffered
// on stdout/stderr when the stream is a pipe — which is exactly how this helper
// is always invoked. The caller sees the verdict; the exit STATUS is set on the
// way out instead.
class UsageError extends Error {}

function usage(message) {
  process.stderr.write('ai-quotas-cursor.js: ' + message + '\n');
  process.stderr.write(
    'Usage: ai-quotas-cursor.js --profile-dir <dir> [--mode read|login] ' +
      '[--timeout-ms <n>] [--url <u>] [--endpoint <path>]\n'
  );
  throw new UsageError(message);
}

function parseArgs(argv) {
  const opts = { profileDir: '', mode: 'read', help: false, timeoutMs: null, url: DEFAULT_URL, endpoint: DEFAULT_ENDPOINT };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const need = () => {
      if (i + 1 >= argv.length || !argv[i + 1]) usage(a + ' requires a value');
      return argv[++i];
    };
    switch (a) {
      case '-h':
      case '--help':
        opts.help = true;
        return opts;
      case '--profile-dir': opts.profileDir = need(); break;
      case '--mode': opts.mode = need(); break;
      case '--timeout-ms': opts.timeoutMs = need(); break;
      case '--url': opts.url = need(); break;
      case '--endpoint': opts.endpoint = need(); break;
      default: usage('unknown argument: ' + a);
    }
  }
  if (!opts.profileDir) usage('--profile-dir is required');
  if (opts.mode !== 'read' && opts.mode !== 'login') usage("--mode must be 'read' or 'login'");
  if (opts.timeoutMs !== null) {
    // A bound arithmetic cannot read is worse than no bound: NaN comparisons
    // are always false, so every wait would fall through instantly and report
    // itself as a timeout — a degradation wearing a timeout's clothes.
    if (!/^[1-9][0-9]*$/.test(opts.timeoutMs)) usage('--timeout-ms must be a positive integer of milliseconds');
    opts.timeoutMs = Number(opts.timeoutMs);
    // The regex above passes any length of digits; the range check is what
    // keeps the parsed value a real deadline (see MAX_TIMEOUT_MS).
    if (!Number.isSafeInteger(opts.timeoutMs) || opts.timeoutMs > MAX_TIMEOUT_MS) {
      usage('--timeout-ms must be between 1 and ' + MAX_TIMEOUT_MS + ' milliseconds');
    }
  } else {
    opts.timeoutMs = opts.mode === 'login' ? DEFAULT_LOGIN_TIMEOUT_MS : DEFAULT_READ_TIMEOUT_MS;
  }
  return opts;
}

function helpText() {
  return [
    'ai-quotas-cursor.js — read one Cursor account\'s monthly pools via a saved browser session.',
    '',
    'Usage:',
    '  ai-quotas-cursor.js --profile-dir <dir> [--mode read|login] [--timeout-ms <n>]',
    '                      [--url <u>] [--endpoint <path>]',
    '',
    'Prints exactly one JSON object on stdout: status ok | needs-login | unreadable | unreachable.',
    'Exit 0 when a verdict was printed; exit 2 on a usage error.',
    'Reference: .claude/reference/ai-quotas.md',
    ''
  ].join('\n');
}

function loadPlaywright() {
  try {
    // eslint-disable-next-line global-require
    return require('playwright');
  } catch (err) {
    return null;
  }
}

// ms since the epoch, as the payload sends it — a decimal STRING today, but a
// number is accepted too rather than betting the reset column on the type.
// The one place a payload value becomes a number, because there is exactly one
// way to get this wrong and it is silent: `Number('')` and `Number(' ')` are
// `0`, not NaN. A blank `autoPercentUsed` would therefore pass every finite
// check and render as `0 %` — "plenty left" — which is the precise opposite of
// "we do not know", and the bash reader, which only rejects NON-numeric
// strings, would pass it straight through. A blank field is an ABSENT figure.
function toNumberOrNull(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const s = String(value).trim();
  if (s === '') return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

function msToEpochSeconds(value) {
  const n = toNumberOrNull(value);
  if (n === null || n <= 0) return null;
  return Math.floor(n / 1000);
}

function centsToUsd(value) {
  const n = toNumberOrNull(value);
  if (n === null) return null;
  return Math.round(n) / 100;
}

function asPercent(value) {
  const n = toNumberOrNull(value);
  if (n === null || n < 0) return null;
  return n;
}

// Turns the captured payload into the flat contract the bash reader consumes.
// Returns { ok: true, row } or { ok: false, keysSeen, detail }.
function normalise(payload) {
  const keysSeen = payload && typeof payload === 'object' && !Array.isArray(payload)
    ? Object.keys(payload)
    : [];
  if (!keysSeen.length) {
    return { ok: false, keysSeen, detail: 'the usage response was not a JSON object' };
  }
  const usage_ = payload.planUsage;
  if (!usage_ || typeof usage_ !== 'object') {
    return { ok: false, keysSeen, detail: 'no planUsage object in the usage response' };
  }
  const auto = asPercent(usage_.autoPercentUsed);
  const api = asPercent(usage_.apiPercentUsed);
  if (auto === null && api === null) {
    return {
      ok: false,
      keysSeen: Object.keys(usage_),
      detail: 'planUsage carried neither autoPercentUsed nor apiPercentUsed'
    };
  }
  const pools = [];
  // A pool whose percentage this reader could not parse is OMITTED, never
  // emitted as 0: the bash side then renders it as a missing figure and says
  // which key it was looking for.
  if (auto !== null) pools.push({ pool: 'cursor-models', used_pct: auto });
  if (api !== null) pools.push({ pool: 'other-models', used_pct: api });

  // The on-demand block: what this account has already spent past its
  // included usage, against the limit it set. #1669 renders it as the live
  // Cursor overage figure. Absent or malformed leaves both fields null, and
  // the reader falls back to the checked-in "on-demand" label — a missing
  // block must not read as "$0 spent", which is the reassuring direction.
  const spend = payload.spendLimitUsage && typeof payload.spendLimitUsage === 'object'
    && !Array.isArray(payload.spendLimitUsage)
    ? payload.spendLimitUsage
    : null;

  return {
    ok: true,
    row: {
      billing_cycle_start_epoch: msToEpochSeconds(payload.billingCycleStart),
      billing_cycle_end_epoch: msToEpochSeconds(payload.billingCycleEnd),
      pools,
      // Cents, like every other dollar figure in this payload.
      spend_limit_used_usd: spend ? centsToUsd(spend.individualUsed) : null,
      spend_limit_usd: spend ? centsToUsd(spend.individualLimit) : null,
      // Plan-WIDE dollars. The captured response carries no per-pool dollar
      // split — the Spending tab itself renders the two pools as percentage
      // bars — so these are reported as what they are and never divided up to
      // manufacture a per-pool figure.
      plan_used_usd: centsToUsd(usage_.totalSpend),
      plan_included_usd: centsToUsd(usage_.limit !== undefined ? usage_.limit : usage_.includedSpend)
    }
  };
}

// True when `url`'s path IS `wanted` — an exact path comparison, deliberately
// not a suffix one. A suffix test also matches `/debug/api/dashboard/
// get-current-period-usage`, `/mock/...`, or anything else a proxy, a preview
// deployment, or a future rewrite can hang in front of the real path, and this
// helper would read quota figures off whatever answered there. A URL it cannot
// parse is likewise not a match — better a timeout that says "the dashboard
// never asked" than a figure read off a response nobody identified. The query
// string is ignored, because `pathname` excludes it.
function pathIs(url, wanted) {
  let pathname;
  try {
    pathname = new URL(url).pathname;
  } catch (err) {
    return false;
  }
  return pathname === wanted;
}

function looksLikeLoginUrl(url) {
  const lower = String(url || '').toLowerCase();
  return LOGIN_URL_MARKERS.some((m) => lower.includes(m));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(helpText());
    return;
  }

  const playwright = loadPlaywright();
  if (!playwright) {
    emit({
      status: 'unreachable',
      detail:
        'playwright is not installed for this helper — run: npm install --prefix .claude/scripts/lib ' +
        '&& npx --prefix .claude/scripts/lib playwright install chromium'
    });
    return;
  }

  let context = null;
  try {
    try {
      context = await playwright.chromium.launchPersistentContext(opts.profileDir, {
        headless: opts.mode === 'read',
        viewport: { width: 1280, height: 900 }
      });
    } catch (err) {
      emit({
        status: 'unreachable',
        detail:
          'could not launch chromium on this profile (' +
          String(err && err.message ? err.message : err).slice(0, 200) +
          ') — the browser binary may be missing: npx --prefix .claude/scripts/lib playwright install chromium'
      });
      return;
    }

    const page = context.pages().length ? context.pages()[0] : await context.newPage();

    // ONE deadline for the whole run, not one per stage. Giving the
    // navigation, the capture wait, and the fallback request a full
    // opts.timeoutMs each lets a slow account consume two or three times the
    // bound it was given — and the bash reader kills the helper at ITS bound,
    // so the overrun surfaces as "the helper did not finish" rather than as
    // the honest per-stage verdict this code went to the trouble of building.
    const runDeadline = Date.now() + opts.timeoutMs;
    const remaining = () => Math.max(0, runDeadline - Date.now());

    // The listener is installed BEFORE the navigation. Installed after, it
    // races the page's own fetch and loses on a warm profile — which would
    // read as "the dashboard never asked", i.e. a timeout, for an account
    // that answered correctly.
    let captured = null;
    let claimed = false;
    let capturedUrl = null;
    // Which path produced the figures. Tracked in its own flag rather than
    // inferred from capturedUrl, which BOTH paths set — inferring it would
    // report every fallback read as an observed one, hiding exactly the
    // degradation the field exists to make visible.
    let source = 'network';
    let planName = null;
    let sawUnauthorized = null;

    const onResponse = async (response) => {
      const url = response.url();
      try {
        if (pathIs(url, opts.endpoint)) {
          if (response.status() === 401 || response.status() === 403) {
            sawUnauthorized = response.status();
            return;
          }
          if (response.status() === 200) {
            // Clear the earlier rejection. A login run ALWAYS starts
            // unauthenticated — that first 401 is the reason the window is
            // open — so letting it stand would make the flow report
            // `needs-login` for a login that then succeeded.
            sawUnauthorized = null;
            // The claim is staked BEFORE the await. `response.json()` yields,
            // so two matching responses arriving together would both pass a
            // `!captured` test and the second would overwrite the first —
            // silently reporting whichever body happened to parse last.
            if (!claimed) {
              claimed = true;
              try {
                const body = await response.json();
                captured = body;
                capturedUrl = url;
              } catch (parseErr) {
                // Release the claim. A body that would not parse is not an
                // answer, and holding the claim would lock out every later
                // response for this endpoint — the run would wait out its
                // whole bound with a good response sitting unread.
                claimed = false;
                throw parseErr;
              }
            }
          }
        } else if (pathIs(url, PLAN_ENDPOINT) && response.status() === 200 && planName === null) {
          const body = await response.json();
          const info = body && body.planInfo;
          if (info && typeof info.planName === 'string') planName = info.planName;
        }
      } catch (err) {
        // A body that is not JSON is not a crash: the shape check below is the
        // place that reports it, with the keys it actually saw.
      }
    };
    page.on('response', onResponse);

    try {
      await page.goto(opts.url, { waitUntil: 'domcontentloaded', timeout: remaining() });
    } catch (err) {
      emit({
        status: 'unreachable',
        detail: 'could not load ' + opts.url + ' (' + String(err && err.message ? err.message : err).slice(0, 160) + ')'
      });
      return;
    }

    while (!captured && Date.now() < runDeadline) {
      // Both early exits are READ-ONLY. In login mode the user is EXPECTED to
      // arrive unauthenticated and sit on the login page; bailing on either
      // signal there is the whole flow failing at step one, every time.
      if (opts.mode === 'read' && sawUnauthorized) break;
      if (opts.mode === 'read' && looksLikeLoginUrl(page.url())) break;
      await page.waitForTimeout(250);
    }

    if (!captured && sawUnauthorized) {
      emit({
        status: 'needs-login',
        detail: 'the dashboard rejected this saved session (HTTP ' + sawUnauthorized + ')'
      });
      return;
    }
    if (!captured && opts.mode === 'read' && looksLikeLoginUrl(page.url())) {
      emit({ status: 'needs-login', detail: 'the dashboard redirected to a login page — the saved session is gone' });
      return;
    }

    // Fallback: ask for the response the page did not (re-)request. Same
    // origin, same session, same endpoint — this is the page's own call, made
    // once explicitly, not a different API.
    if (!captured) {
      let fetched;
      try {
        // Raced against the same deadline: an endpoint that accepts the
        // request and never answers would otherwise hang here forever, past
        // every bound above it.
        fetched = await Promise.race([
          page.evaluate(async (endpoint) => {
            const res = await fetch(endpoint, {
              method: 'POST',
              credentials: 'include',
              headers: { 'Content-Type': 'application/json' },
              body: '{}'
            });
            let body = null;
            try {
              body = await res.json();
            } catch (e) {
              body = null;
            }
            return { status: res.status, body };
          }, opts.endpoint),
          new Promise((resolve) => {
            // .unref() so the loser of the race does not hold the event loop
            // open. Without it the process sits idle until this timer fires —
            // up to the whole bound — long after the verdict was printed, and
            // the bash probe kills it there and reports a timeout for a read
            // that had already succeeded.
            const timer = setTimeout(() => resolve(null), Math.max(1000, remaining()));
            if (typeof timer.unref === 'function') timer.unref();
          })
        ]);
      } catch (err) {
        emit({
          status: 'unreachable',
          detail:
            'the dashboard never requested ' +
            opts.endpoint +
            ' within ' +
            opts.timeoutMs +
            'ms and the direct request failed (' +
            String(err && err.message ? err.message : err).slice(0, 160) +
            ')'
        });
        return;
      }
      if (!fetched) {
        emit({
          status: 'unreachable',
          detail:
            'the dashboard never requested ' + opts.endpoint + ' and the direct request did not answer within ' +
            opts.timeoutMs + 'ms'
        });
        return;
      }
      if (fetched.status === 401 || fetched.status === 403) {
        emit({ status: 'needs-login', detail: 'the usage endpoint rejected this saved session (HTTP ' + fetched.status + ')' });
        return;
      }
      if (fetched.status !== 200 || !fetched.body) {
        emit({
          status: 'unreachable',
          detail: 'the usage endpoint answered HTTP ' + fetched.status + ' with no JSON body'
        });
        return;
      }
      captured = fetched.body;
      capturedUrl = new URL(opts.endpoint, opts.url).toString();
      source = 'fetch';
    }

    const shaped = normalise(captured);
    if (!shaped.ok) {
      emit({
        status: 'unreadable',
        detail: shaped.detail,
        keys_seen: shaped.keysSeen,
        endpoint: capturedUrl
      });
      return;
    }

    emit(
      Object.assign(
        { status: 'ok', source: source, endpoint: capturedUrl },
        shaped.row,
        { plan_name: planName }
      )
    );
  } catch (err) {
    emit({ status: 'unreachable', detail: String(err && err.message ? err.message : err).slice(0, 200) });
  } finally {
    if (context) {
      try {
        await context.close();
      } catch (err) {
        // Closing is best effort; a verdict has already been printed and a
        // close failure must not turn a good read into a bad exit status.
      }
    }
  }
}

// No process.exit() on either path. Node exits on its own once the event loop
// drains, which is what lets a piped stdout finish flushing — and the browser
// context is closed in main()'s finally, so nothing is left holding the loop
// open. `process.exitCode` carries the status without cutting the write short.
// Required as a module (the test suite), this file exports its pure helpers
// and runs nothing. Executed directly, it runs. Without this guard a test that
// merely imported the file would launch a browser.
if (require.main !== module) {
  module.exports = { normalise, pathIs, msToEpochSeconds, centsToUsd, asPercent };
} else {
  runMain();
}

function runMain() {
main().then(
  () => {
    process.exitCode = 0;
  },
  (err) => {
    if (err instanceof UsageError) {
      // The message is already on stderr and there is no verdict to print:
      // a usage error means the run never had an account to report on.
      process.exitCode = 2;
      return;
    }
    // Last resort. Even here the caller gets a verdict rather than a bare
    // stack trace, because the bash reader's contract is "one JSON object".
    emit({ status: 'unreachable', detail: 'helper failed: ' + String(err && err.message ? err.message : err).slice(0, 200) });
    process.exitCode = 0;
  }
);
}
