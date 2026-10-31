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

4. **Scriptable sign-in (`gmailmenubar://` URL scheme)**, for another Claude session that drives its own Chrome tab (a menu-bar app and the ASWebAuthenticationSession sheet can't be driven by computer use).
   - Code: `Automation/AutomationCommand.swift` (URL parsing + file paths), `Automation/AutomationStatus.swift` (status JSON), loopback flow in `Auth/AppAuthAuthorizer.swift` (`SignInMode.externalBrowser`), handling in `App/AppDelegate.swift` (`application(_:open:)`).
   - Files live in `~/Library/Application Support/Gmail/`, mode 0600, never contain tokens or the client secret.
   - `open "gmailmenubar://add-account?login_hint=<email>"` (login_hint optional): starts a loopback listener on `http://127.0.0.1:<random port>/`, writes the Google consent URL to `pending-auth-url.txt` and opens no browser. Params: `access_type=offline`, `prompt=consent`, `login_hint`. Open that URL in Chrome, pick/confirm the account, click Allow; Google redirects to 127.0.0.1, the app finishes like the normal flow (token exchange, profile email, Keychain, add/replace account, polling), deletes `pending-auth-url.txt` and writes the result. Times out after 5 minutes. A new add-account request cancels a pending one (its result shows `org.openid.appauth.general -4 ... cancelled programmatically`). Relaunching the app deletes a stale pending file.
   - `open "gmailmenubar://status"` rewrites `accounts-status.json` now. It is also rewritten at launch, after every add-account attempt (URL or in-app button) and after every poll tick. Shape: `{updatedAt, addAccountInProgress, accounts: [{email, state: ok|needsReauth|error, unreadCount, lastError?}], lastAddAccount?: {email?, ok, error?, loginHint?, finishedAt}}`. `lastAddAccount` survives relaunch.
   - Loop for each account: `open add-account` -> wait for `pending-auth-url.txt` -> open it in Chrome -> consent -> wait until the file is gone and `addAccountInProgress` is false -> check `lastAddAccount.ok` and `email`.
   - Demo mode (`GMAIL_DEMO=1`) ignores these URLs.

Screenshots: `docs/popover-demo-top.png`, `docs/popover-demo-bottom.png` (demo data).

## Build / test

```bash
swift test                               # 130 tests (76 upstream + 54 new)
./scripts/build.sh                       # reads OAuth client from Keychain
ALLOW_UNCONFIGURED=1 ./scripts/build.sh  # UI-only build, no Google sign-in
```

Install after a build (login item points at /Applications):

```bash
pkill -f "/Applications/Gmail.app/Contents/MacOS/Gmail"
ditto Gmail.app /Applications/Gmail.app && xattr -dr com.apple.quarantine /Applications/Gmail.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Gmail.app
open /Applications/Gmail.app
```

Keychain item names (saved with `~/noah-brain/bin/save-secret`): `gmail-menubar-client-id`, `gmail-menubar-client-secret`. Never commit them.

## Left to do

- Google Cloud project `gmail-menu-bar-513315` is In production (Desktop client, scope gmail.modify) and the real build is installed in /Applications. Next: add Noah's ~7 accounts through `gmailmenubar://add-account` (see 4). The loopback flow was smoke-tested up to the consent URL only; a full live sign-in is still untested.
- Workspace accounts may need the admin to trust the client ID (see SETUP.md).
- Bundle id / Keychain service still `com.pezy.gmail*`. Rename if Noah wants it fully his (would need re-sign-in).
- Changing the poll interval only applies after the next pause/resume (upstream behavior).
- Ideas: reorder accounts, per-account mute, notarized build like Double Shot.
