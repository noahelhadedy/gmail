# Gmail macOS Client (Noah's multi-account fork)

Noah's own menu bar app, personal stream. Read HANDOFF.md first for status and what's left.

- Branch `noah/multi-account`. Commit locally; **never push** unless Noah asks (fork is public).
- Swift 6 strict concurrency, AppKit NSStatusItem + NSPopover + SwiftUI, one `@MainActor @Observable AppState`.
- Multi-account: `AppState.accounts: [AccountState]`; `AccountManager` owns one `AuthService` + `PollingCoordinator` per account. Never let one account's error touch another's state.
- OAuth client is never in the repo: `scripts/build.sh` reads Keychain items `gmail-menubar-client-id` / `gmail-menubar-client-secret` (setup steps in SETUP.md, Arabic).
- Native macOS look only: system fonts, SF Symbols, system colors and materials. No gradients, glows or custom chips.
- `swift test` must stay green. UI check: `ALLOW_UNCONFIGURED=1 ./scripts/build.sh && GMAIL_DEMO=1 ./Gmail.app/Contents/MacOS/Gmail`.


## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
