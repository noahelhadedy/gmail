import Foundation

/// Sample accounts for screenshots and UI checks without Google sign-in.
/// Enabled only when the app is launched with `GMAIL_DEMO=1`; nothing is polled.
@MainActor
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GMAIL_DEMO"] == "1"
    }

    static func populate(_ appState: AppState) {
        let now = Date()
        func message(_ id: String, _ from: String, _ subject: String, _ snippet: String, minutesAgo: Double) -> EmailMessage {
            EmailMessage(
                id: id, threadId: id, from: from, subject: subject,
                internalDate: now.addingTimeInterval(-minutesAgo * 60), snippet: snippet
            )
        }

        let personal = AccountState(email: "you@gmail.com", colorIndex: 0)
        personal.unreadCount = 12
        personal.emails = [
            message("p1", "GitHub <noreply@github.com>", "New pull request on your repo", "A contributor opened a pull request with 3 commits.", minutesAgo: 4),
            message("p2", "Figma <no-reply@figma.com>", "You were mentioned in a comment", "Can we try the darker variant on this screen?", minutesAgo: 38),
            message("p3", "YouTube <no-reply@youtube.com>", "Your video is now live", "Thanks for uploading. Here is how it is doing so far.", minutesAgo: 95),
            message("p4", "Apple <no_reply@email.apple.com>", "Your receipt from Apple", "Receipt for your recent purchase.", minutesAgo: 240),
            message("p5", "Google <no-reply@accounts.google.com>", "Security alert", "A new sign-in on Mac.", minutesAgo: 600)
        ]

        let studio = AccountState(email: "hello@studio.com", colorIndex: 1)
        studio.unreadCount = 2
        studio.emails = [
            message("s1", "Polar <hi@polar.sh>", "You made a sale", "Someone bought your template. Payout is on the way.", minutesAgo: 12),
            message("s2", "Client <client@example.com>", "Re: Website proposal", "Thanks, the timeline works for us. Let&#39;s start Monday.", minutesAgo: 70)
        ]

        let work = AccountState(email: "you@company.com", colorIndex: 2)
        work.unreadCount = 0
        work.loadState = .loaded

        let expired = AccountState(email: "old@workspace.com", colorIndex: 3, authState: .needsReauthorization)

        appState.accounts = [personal, studio, work, expired]
        appState.connectionState = .online
        appState.isConfigured = true
    }
}
