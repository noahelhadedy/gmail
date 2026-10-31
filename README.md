<h4 align="right">English | <strong><a href="README_zh.md">简体中文</a></strong></h4>

<p align="center">
  <img src="https://img.shields.io/badge/-Gmail-EA4335?logo=gmail&logoColor=white&style=for-the-badge" width="138" />
  <h1 align="center">Gmail</h1>
  <div align="center">
    <a href="https://github.com/pezy/gmail/releases" target="_blank">
      <img alt="Status" src="https://img.shields.io/badge/status-beta-orange?style=flat-square"></a>
    <a href="LICENSE" target="_blank">
      <img alt="License" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square"></a>
    <img alt="Swift 6.0+" src="https://img.shields.io/badge/Swift-6.0%2B-F05138?style=flat-square&logo=swift&logoColor=white">
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-orange?style=flat-square">
  </div>
  <div align="center">A minimalist Gmail menu bar app for macOS. Native notifications, nothing else.</div>
</p>

## Why

There is no good open-source Gmail client for macOS. The web client lacks native notifications and a Dock badge. Mimestream is paid and closed. Mail.app does not feel like Gmail. Electron clients are heavy.

This app does one thing: tells you when new mail arrives. Click the notification to open the message in your browser. That is it.

## Features

- **Zoho Mail too** (optional) — a Zoho mailbox shows next to the Gmail accounts, see SETUP-ZOHO.md
- **Menu bar only** — `LSUIElement=true`, no Dock icon, no main window
- **Native notifications** — UNUserNotificationCenter, click to open in browser
- **Incremental polling** — `users.history.list` keeps steady-state at ~1-3 quota units per poll
- **Status-aware icon** — auth ⚠️ yellow, network grey, API ⚠️ red, normal black (priority resolved)
- **Quad empty states** — signed-out, needs reauthorization, inbox zero, error with retry
- **Configurable polling** — 60s default, 120s / 5min / 10min via Settings
- **Launch at login** — SMAppService toggle in Settings
- **Multiple accounts** — add any number of Google accounts; each is polled on its own and can fail or need sign-in without affecting the others
- **Total unread in the menu bar** — sum of every account's INBOX unread count, hidden at zero
- **Grouped popover** — one section per account (color dot + unread count), latest 5 unread with snippet, Open Inbox, Mark as read
- **Multi-account-safe URLs** — every click opens the right inbox via `?authuser=<email>`

## System Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15+ (`xcode-select --install`)
- A Google Cloud OAuth 2.0 Client ID (Desktop app type)

## Installation

> ⚠️ **v1.0.0-beta** — source build only. The `.dmg` and Homebrew cask will follow once Google OAuth verification clears.

### 1. Create Google Cloud OAuth credentials

1. Open the [Google Cloud Console — Credentials page](https://console.cloud.google.com/apis/credentials).
2. Pick an existing project or create a new one.
3. Enable Gmail API: **APIs & Services → Library → Gmail API → Enable**.
4. Configure the OAuth consent screen (User Type = External, Publishing status = Testing).
5. **Create Credentials → OAuth client ID → Application type = Desktop app**.
6. Copy both the **Client ID** (`123-abc.apps.googleusercontent.com`) and **Client Secret** (`GOCSPX-...`).

> **Testing-status caveats** (Google rules, not ours):
>
> - Only Google accounts added to the consent screen's *Test users* list can sign in.
> - Refresh tokens expire after 7 days. The app will prompt you to sign in again.
>
> Submit OAuth verification (privacy policy URL required, ~4 weeks) to remove these limits.

### 2. Build

```bash
git clone https://github.com/pezy/gmail.git
cd gmail
OAUTH_CLIENT_ID="123-abc.apps.googleusercontent.com" \
OAUTH_CLIENT_SECRET="GOCSPX-..." \
./scripts/build.sh
```

The script writes `Gmail.app` to the repo root.

### 3. Run

```bash
xattr -d com.apple.quarantine Gmail.app  # bypass Gatekeeper for unsigned binary
open Gmail.app
```

The menu bar shows ✉. Click → **Connect Gmail** → finish the OAuth flow in Safari → unread mail appears within seconds.

## Usage

- **Click ✉ in the menu bar** to toggle the popover.
- **Click a row** to open the message in your default browser.
- **⚙ icon** in the popover footer opens Settings.
- **Sign-out icon** in the footer clears tokens and resets state. Use this if anything ever feels stuck.

## Tests

```bash
swift test
```

67 unit tests covering OAuth state machine, Keychain round-trip, Gmail API parsing, polling state machine, notification dedup, status bar presenter, and settings persistence.

## Roadmap

See [TODOS.md](TODOS.md) for deferred work, including:

- Quick Look message preview (spacebar)
- `.dmg` distribution + Homebrew cask
- Sparkle auto-update
- Mac App Store distribution

## Tech Stack

- **Language**: Swift 6 (strict concurrency)
- **UI**: SwiftUI + AppKit (`NSStatusItem`, `NSPopover`, `NSPanel`, `NSWindow`)
- **OAuth**: [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) (the only third-party dependency)
- **Networking**: `URLSession`
- **Notifications**: `UNUserNotificationCenter`
- **Token storage**: Security framework (Keychain), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- **Auto-start**: `SMAppService`
- **Polling**: `NSBackgroundActivityScheduler`
- **Network monitoring**: `NWPathMonitor`

## Architecture

Ten focused modules behind a single `@MainActor @Observable AppState`:

```
AuthService -- AppAuthAuthorizer -- KeychainService
GmailAPIClient -- HTTPS to gmail.googleapis.com
PollingCoordinator (state machine) -- NetworkMonitor
NotificationManager (UNUserNotificationCenter)
StatusBarController + PopoverView + SettingsView (UI)
LoginItemsManager (SMAppService)
```

See [the design document](https://github.com/pezy/gmail/blob/main/CLAUDE.md) for the full architecture diagram and decision log.

## Acknowledgements

- [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) by Google for handling OAuth correctly so we did not have to.
- [MiaoYan](https://github.com/tw93/MiaoYan) for the README format inspiration.

## License

[MIT](LICENSE)
