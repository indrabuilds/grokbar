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
- **"Show days left" toggle** (gear → Menu bar). On: `42% · 3d`; off: `42%`.
  - Source: the billing period end, `config.currentPeriod.end` (fallback `config.billingPeriodEnd`) from the same
    Grok billing response. Nothing else is fetched.
  - Rounding: whole days remaining, rounded down (3 d 20 h → `3d`); under 24 h → `<1d`. A missing or past reset date
    shows the percentage only (no "now"/"?" placeholder).
  - Stored in UserDefaults key `showDaysLeft` (Bool, **default off**, so the bar shows just the percentage until the
    user opts in). The default is only registered (`register(defaults:)`, in memory); the key is written solely by the
    toggle's `didSet`, which Swift doesn't run during `init`, and the KVO observer only mirrors external changes. So
    indra.2 never stored `true` on its own, and no migration is needed: untouched installs start off, and anyone who
    switched it on keeps their choice. Changing it in the popover updates the menu bar at once via a Combine sink on
    `$showDaysLeft`; a KVO observer on `UserDefaults` also picks up `defaults write … showDaysLeft` while the app runs,
    so this pref is not launch-only.
- **Status item click toggles the popover.** Clicking the item while the popover is open now closes it instead of
  closing and immediately reopening it. A `.transient` popover dismisses itself on the same mouse-down that hits the
  status item; the controller now acts on mouse-down, records the close time in `popoverWillClose`/`popoverDidClose`
  (`NSPopoverDelegate`), and ignores a reopen within 0.3 s of a close. Clicking in another app (global monitor),
  clicking elsewhere (transient behavior) and Esc (local key monitor, keyCode 53) still close it; monitors are removed
  in `popoverDidClose`.
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
  7. Gear → toggle "Show days left": the bar switches between `42%` and `42% · 3d` immediately; same with
     `defaults write com.pixbroker.GrokBar showDaysLeft -bool false|true` while running.
  8. Click the item twice: it opens, then closes (no flicker/reopen). Click outside and press Esc: it closes.

## Menu bar icon: unchanged, and why

The request was to swap the SuperGrok mark for the Grok Bot icon only if an official, properly licensed asset exists.
None was found, so the icon is unchanged (still `GrokIcon*` from 1.1.0) and nothing was redrawn.

- **xAI Brand Guidelines** (https://x.ai/legal/brand-guidelines, dated Feb 14, 2025): logos may be used only
  "exactly as provided at the download link … without any alteration or adjustment", only to refer to xAI/Grok, not in
  ways implying endorsement, and xAI "may terminate your permission … at any time". This is a revocable trademark
  permission, not a license.
- **Official download** (https://data.x.ai/logos/xAI_Grok_Assets.zip, fetched Oct 24, 2026): Grok logomark, Grok full
  logomark, Grok wordmark and xAI logomarks in Dark/Light SVG/PNG. **No Grok Bot mark** is included.
- **Grok Bot mark elsewhere:** only inline on xAI's own pages, an App Store icon (X Corp.), a press handout distributed
  through Europa Press for news use, and third-party re-hosts (asvg.app, toolradar.com, iloveicons.app) that state the
  download grants no trademark permission. None is an official, permitted asset for use in an app.
- Converting any mark into a monochrome template would also be an "alteration" under the guidelines.
- Note: the repo's existing `Resources/GrokBotIcon.svg` (from the upstream initial commit, used only by the removed Grok
  Bot card) has no recorded source or license; it was not used for the menu bar.
- The existing Grok mark: the official kit's Grok logomark is the authoritative source; the upstream `GrokIcon*` files
  predate this PR and were not changed. To switch to Grok Bot later, ask legal@x.ai or wait for xAI to add a Grok Bot
  mark to the official kit.
