# HANDOFF: gmail-menubar (Noah's multi-account fork)

Fork of [pezy/gmail](https://github.com/pezy/gmail) (MIT). Fork lives at github.com/noahelhadedy/gmail (public).
Local work is on branch `noah/multi-account`. **Nothing is pushed.** Noah decides when to push.
Remotes: `origin` = noahelhadedy/gmail, `upstream` = pezy/gmail.

## Done (31 Oct 2026)

1. **Multiple Google accounts at once**
   - `Accounts/AccountStore.swift`: ordered account list + dot color in UserDefaults (`accounts.list`). Migrates the old single-account key once.
   - `Accounts/AccountManager.swift`: one `AuthService` + `PollingCoordinator` + scheduler per account. Add / remove / sign in again / refresh / mark as read. Accounts tick concurrently.
   - Tokens in Keychain keyed by email (service `com.pezy.gmail.tokens`, unchanged).
   - Per-account history pointer: `lastHistoryId.<email>` / `lastFetchTime.<email>`.
   - Account with missing/revoked tokens shows "Session expired / Sign In Again"; others keep polling.
   - Token refresh failing for **network** reasons no longer wipes tokens (`AppAuthAuthorizer.mapRefreshError` + `AuthService`).
2. **Total unread in the menu bar**: `AppState.totalUnreadCount` (sum of each account's `labels.get(INBOX).messagesUnread`), hidden at 0. Count re-fetched on every poll (1 quota unit). Interval setting kept (60s default).
3. **Popover grouped by account**: header = color dot + email + unread count; up to 5 unread (sender, time, subject, 1-line snippet); "Open Inbox" + "N more unread"; click opens Gmail with `?authuser=<email>`; hover/right-click "Mark as read" (scope is now `gmail.modify`).
   - Notifications per account: subtitle = account email, click opens that account. The Settings "notifications" toggle is now honored (it was ignored upstream).
   - Settings: Accounts section (add, remove with confirm, sign in again).
   - App runs without a client ID (shows "Setup Needed") instead of quitting.
   - `GMAIL_DEMO=1 ./Gmail.app/Contents/MacOS/Gmail` = sample data for screenshots, no network.

Screenshots: `docs/popover-demo-top.png`, `docs/popover-demo-bottom.png` (demo data).

## Build / test

```bash
swift test                               # 119 tests (76 upstream + 43 new)
./scripts/build.sh                       # reads OAuth client from Keychain
ALLOW_UNCONFIGURED=1 ./scripts/build.sh  # UI-only build, no Google sign-in
```

Keychain item names (saved with `~/noah-brain/bin/save-secret`): `gmail-menubar-client-id`, `gmail-menubar-client-secret`. Never commit them.

## Left to do

- Noah: Google Cloud steps in `SETUP.md`, then real sign-in test with all ~5 accounts (not tested against live Gmail yet; only unit tests + demo UI).
- Workspace accounts may need the admin to trust the client ID (see SETUP.md).
- Bundle id / Keychain service still `com.pezy.gmail*`. Rename if Noah wants it fully his (would need re-sign-in).
- Changing the poll interval only applies after the next pause/resume (upstream behavior).
- Ideas: reorder accounts, per-account mute, notarized build like Double Shot.
