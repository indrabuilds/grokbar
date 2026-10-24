# One shared usage figure from the Grok session, near-live refresh

## Why

On the X Subscription ($30 Premium), Grok, Grok Bot and Cursor draw from **one weekly pool**.
GrokBar v1.1.0 still shows three separate items, and two of them (Grok Bot, Cursor) depend on
Cursor's own login (`state.vscdb` / `~/.cursor/auth.json`) plus an email match with Grok. That
caused "Cursor session expired" and an empty Cursor card even when Cursor was signed in. Refresh
was also slow (every 20 min, and the popover only refreshed data older than 15 min).

## What changed

- **One item** in the menu bar and popover: the pool `% used` + reset countdown, from
  `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` → `config.creditUsagePercent`
  (period from `config.currentPeriod.{type,start,end}`). The product split (`config.productUsage[]`)
  still shows under it as a breakdown. Percentages from different endpoints are never summed.
- **Grok session only:** `~/.grok/auth.json` (OIDC, refreshed via `auth.x.ai`). Cursor's login, the
  `api2.cursor.sh` calls, the `state.vscdb` SQLite read and the email-match gate are removed
  (`CursorAPI.swift`, `CursorAuthStore.swift` deleted, `-lsqlite3` dropped). Cursor no longer
  needs to be installed or running, and a missing Cursor session can't stall a refresh.
- **Toggles removed.** The gear page now only explains where the number comes from. The old
  `showGrokUsage` / `showGrokBotUsage` / `showCursorUsage` defaults are left as they are and ignored,
  so downgrading back to 1.1.0 keeps the user's old choices.
- **Refresh:**
  - Background poll every **90 s**.
  - Opening the popover always refreshes, at most once per **30 s**.
  - The refresh button is disabled only while a fetch is in flight. `isRefreshing` is now reset on the
    main actor right after the fetch returns, not in a `defer` that spawns another Task.
  - On errors, backoff is exponential: 90 s, 3 min, 6 min, 12 min, then a 15 min cap. HTTP 429 maps to a new
    `UsageFetcherError.rateLimited(retryAfter)`, which honors `Retry-After` given as seconds or an HTTP date,
    capped at 1 h. Setup errors such as being signed out keep the normal 90 s pace, so a new `grok login`
    is picked up quickly.
  - Polling pauses on `NSWorkspace.willSleepNotification`, and the app refreshes and resumes on `didWakeNotification`.
  - The popover shows "Updated <relative time>" (`lastUpdatedAt`; on launch this is the cached snapshot's time).
  - The manual button skips the backoff because the user asked for it. Automatic refreshes respect it.
- The popover activates the app (`NSApp.activate`) when it opens, so the first click reaches its
  buttons in this `LSUIElement` app.
- The usage label uses the pool's own cycle ("weekly" or "monthly") instead of hard-coded "weekly".
- Added `.github/workflows/build.yml`. It runs on `macos-latest` and does the following:
  - runs `build.sh`
  - asserts `CFBundleIdentifier == com.pixbroker.GrokBar`
  - signs the app ad hoc and verifies the signature
  - zips with `ditto` and uploads the `GrokBar` artifact
- Bundle id unchanged (`com.pixbroker.GrokBar`).

## Why 90 seconds

Each poll sends:
- one required small authenticated GET (`/v1/billing?format=credits`)
- three optional GETs for plan, settings and user, which feed the plan name and account shown
- one GET for the public status RSS

The values are per-user aggregates that the server probably updates no more than about once a minute, so polling
more often would add load without adding information. 90 s is about 40 requests/hour per endpoint. That is far below
what interactive clients like `grok` send, and it still makes the bar feel live. Backoff and `Retry-After`
handle any rate limit the server signals. **This is a judgment call.** No published rate limit
for these endpoints was found.

## Which number is authoritative, and what still needs confirming

| Claim | Status |
|---|---|
| `creditUsagePercent` is the % of the current usage period consumed; period type is `USAGE_PERIOD_TYPE_WEEKLY`/`_MONTHLY` | **From code** (existing parser and models, `UsageFetcher.swift`, `Models.swift`) |
| It is the account-level pool, with `productUsage[]` (GrokChat, GrokBuild, …) as its breakdown | **Inferred from the response shape** |
| On the X Subscription, Grok Bot and Cursor usage are counted in that same pool, so it is the single shared figure | **Needs a live response to confirm.** Check that `productUsage[]` lists a Grok Bot/Cursor product, or that `creditUsagePercent` moves after Cursor/Grok Bot use, and compare with the usage page on grok.com |
| A missing `creditUsagePercent` when a `currentPeriod` exists means 0 % (proto3 JSON omits zero values) | **Inferred.** Existing 1.1.0 behavior is unchanged |

**Why not Cursor's `GetSandUsageStatus.usagePercent` or `GetCurrentPeriodUsage.planUsage.*PercentUsed`?**
Those come from Cursor's dashboard, need Cursor's token, and describe Cursor-side allowances: the
Grok Bot weekly pool, and the Cursor monthly "Auto" and "API" pools. If they disagree with Grok's billing, the billing
service that owns the subscription (`cli-chat-proxy` billing) is the more authoritative source. It also needs only the
Grok session. If live testing shows the Grok endpoint doesn't include Cursor or Grok Bot consumption, the fallback would be
to read Cursor's token from `state.vscdb`. That file can be read even when Cursor isn't running. The Cursor value would be
shown as an optional, clearly labeled secondary figure. It would never be added to the Grok one. That fallback isn't
in this PR, so nothing depends on Cursor.

## Testing

- The changed non-UI sources (`UsageViewModel`, `UsageFetcher`, `Models`, `AuthStore`, `UsageCache`) were type-checked
  with Swift 6.0.3 on Linux against small AppKit/Combine stubs. All files pass `swiftc -parse`.
- The SwiftUI and AppKit views were checked for syntax only. **A real macOS build is still needed.** The new workflow does that build.
- Manual checks on a Mac:
  1. The menu bar shows one Grok item.
  2. Opening the popover triggers a fetch.
  3. The "Updated just now" text appears.
  4. The refresh button is clickable when idle.
  5. Sleeping and waking the Mac triggers a fetch.
  6. Quitting Cursor has no effect.
