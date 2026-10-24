# GrokBar

<p align="center">
  <strong>Grok, Grok Bot, and Cursor usage in the Mac menu bar</strong>
</p>

<p align="center">
  <img src="docs/screenshots/panel-dark.png" alt="GrokBar usage panel on the Mac menu bar" width="720" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT" />
</p>

Unofficial menu bar utility. Same information as [Grokbar for Omarchy](https://github.com/pixbroker/grokbar-omarchy): SuperGrok weekly pool, optional Grok Bot weekly pool, optional Cursor monthly pools. Native AppKit status item and SwiftUI popover.

---

## Menu bar

<p align="center">
  <img src="docs/screenshots/menubar.png" alt="GrokBar in the macOS menu bar" width="720" />
</p>

One item: Grok mark + percent of your usage pool used + time until reset (`5d` / `12h`).

On the X Subscription, Grok, Grok Bot and Cursor draw from one shared pool, so GrokBar shows that single figure, read from your Grok sign-in alone. Cursor does not need to be installed, open, or signed in.

---

## Popover

<p align="center">
  <img src="docs/screenshots/panel-light.png" alt="GrokBar usage panel (light)" width="720" />
</p>

Click the item to open the usage panel (plan, reset countdown, product split); click it again, click outside, or press Esc to close it.

**Show days left** (gear → Menu bar, on by default) adds the days until the pool resets: `42% · 3d`. Whole days, rounded down; under one day shows `<1d`; if the billing response has no reset date the bar shows the percentage only. Off shows `42%`. The setting is stored as `showDaysLeft` and applies immediately, including `defaults write com.pixbroker.GrokBar showDaysLeft -bool false` while the app runs.

- Plan name, weekly or monthly % used, reset date
- Pace marker on the usage bar (where linear usage “should” be)
- SuperGrok product split (Chat, Build, Imagine, Voice, API)
- “Updated … ago” under the usage
- Account name and email (click the plan title)
- Gear for info, circular arrow to refresh now
- xAI status banner when [status.x.ai](https://status.x.ai/) declares an incident

---

## Requirements

- **macOS 14** or later
- SuperGrok: [Grok Build](https://x.ai/build) signed in (`grok login`) so `~/.grok/auth.json` exists

```bash
grok login   # only if ~/.grok/auth.json is missing
```

---

## Install

```bash
git clone https://github.com/pixbroker/grokbar.git
cd grokbar
bash build.sh
cp -R "build/GrokBar.app" /Applications/
open /Applications/GrokBar.app
```

Xcode (or Xcode-beta) is required. **Launch at Login** is registered on first run. Allow GrokBar under **System Settings → General → Login Items** if macOS asks.

Ad-hoc signed builds: first open via **right-click → Open** if Gatekeeper warns.

---

## Behavior

| Situation | What you see |
|-----------|----------------|
| SuperGrok signed in | Grok cluster with weekly % and countdown |
| Not signed in to Grok | `—` and a setup hint; re-checks about every 90 seconds |
| Network blip | Last good SuperGrok snapshot stays in the menu bar |
| Active xAI incident | `⚠` plus a banner in the popover |

Background refresh runs about **every 90 seconds**. Opening the popover always refreshes (at most once per **30 seconds**). On errors GrokBar backs off exponentially (90 s, 3, 6, 12, then 15 min) and honors `Retry-After` on HTTP 429. Polling pauses while the Mac sleeps and refreshes on wake. The countdown ticks locally every minute.

---

## Privacy

| Action | Detail |
|--------|--------|
| **Read** | `~/.grok/auth.json` |
| **Write** | May refresh Grok OIDC tokens in `~/.grok/auth.json` |
| **Network** | `auth.x.ai`, `cli-chat-proxy.grok.com` (usage metadata), `status.x.ai/feed.xml` |
| **Not sent** | Chats, code, project files |

No inference or completions — only usage, subscription metadata, and the public status feed.

---

## How it works

1. Load Grok OIDC credentials from `~/.grok/auth.json` (same file as `grok`).
2. Refresh the access token when near expiry (`auth.x.ai/oauth2/token`).
3. Fetch SuperGrok billing (`/v1/billing?format=credits`) plus plan/profile when available.
4. Fetch the public xAI status RSS feed.
5. Cache the last good SuperGrok snapshot under Application Support.
6. Register as a login item via `SMAppService`.

---

## License

[MIT](LICENSE)

Not affiliated with xAI or Anysphere. Grok, Grok Bot, and Cursor are property of their owners.
