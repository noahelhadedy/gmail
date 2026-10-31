import SwiftUI
import AppKit

/// Stable per-account dot colors, using system colors so they follow the
/// macOS appearance and accessibility settings.
enum AccountColor {
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .indigo]

    static func color(for index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }
}

struct PopoverView: View {
    static let messagesPerAccount = 5

    @Bindable var appState: AppState
    let onRefresh: () -> Void
    let onRefreshAccount: (String) -> Void
    let onAddAccount: () -> Void
    let onReauthorize: (String) -> Void
    let onMarkAsRead: (EmailMessage, String) -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380, height: 480)
    }

    private var isLoading: Bool {
        appState.accounts.contains { $0.loadState == .loading }
    }

    private var header: some View {
        HStack {
            Text("Inbox")
                .font(.headline)
            if appState.totalUnreadCount > 0 {
                Text("\(appState.totalUnreadCount) unread")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isLoading || appState.accounts.isEmpty)
            .help("Check all accounts now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !appState.isConfigured {
            setupRequiredEmpty
        } else if appState.accounts.isEmpty {
            connectGmailEmpty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(appState.accounts) { account in
                        Section {
                            accountBody(account)
                        } header: {
                            AccountHeader(account: account)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountBody(_ account: AccountState) -> some View {
        if account.needsReauthorization {
            AccountNotice(
                symbol: "exclamationmark.triangle",
                tint: .yellow,
                text: "Session expired. Sign in again to keep getting mail.",
                actionTitle: "Sign In Again",
                action: { onReauthorize(account.email) }
            )
        } else if account.loadState == .loading && account.emails.isEmpty {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 10)
        } else if case .failed(let error) = account.loadState, account.emails.isEmpty {
            AccountNotice(
                symbol: "exclamationmark.circle",
                tint: .red,
                text: Self.message(for: error),
                actionTitle: "Retry",
                action: { onRefreshAccount(account.email) }
            )
        } else if account.emails.isEmpty {
            Text("No unread mail")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            ForEach(account.emails.prefix(Self.messagesPerAccount)) { message in
                MessageRow(
                    message: message,
                    onOpen: {
                        NSWorkspace.shared.open(GmailWebURL.thread(email: account.email, threadId: message.threadId))
                    },
                    onMarkAsRead: { onMarkAsRead(message, account.email) }
                )
            }
        }
        if !account.needsReauthorization {
            OpenInboxRow(
                hiddenCount: max(0, account.unreadCount - min(account.emails.count, Self.messagesPerAccount)),
                action: { NSWorkspace.shared.open(GmailWebURL.inbox(email: account.email)) }
            )
        }
    }

    private var setupRequiredEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "key")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Setup Needed")
                .font(.headline)
            Text("This build has no Google OAuth client ID. Follow SETUP.md, then rebuild with scripts/build.sh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account", action: onAddAccount)
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectGmailEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Connect Gmail")
                .font(.headline)
            Text("Add one or more Google accounts to see unread mail and get notifications.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account", action: onAddAccount)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: onAddAccount) {
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(!appState.isConfigured)
            .help("Add Google account")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Gmail (\u{2318}Q)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerText: String {
        switch appState.accounts.count {
        case 0: return ""
        case 1: return "1 account"
        default: return "\(appState.accounts.count) accounts"
        }
    }

    static func message(for error: AppError) -> String {
        switch error {
        case .auth(.refreshTokenInvalid):
            return "Your Gmail session expired."
        case .network:
            return "Network unavailable."
        case .api(.rateLimited):
            return "Too many requests. Backing off."
        case .api(.serverError(let status)):
            return "Server error (HTTP \(status))."
        case .api:
            return "Gmail API error."
        case .notification:
            return "Notification error."
        case .auth:
            return "Authentication error."
        }
    }
}

private struct AccountHeader: View {
    let account: AccountState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AccountColor.color(for: account.colorIndex))
                .frame(width: 8, height: 8)
            Text(account.email)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if account.needsReauthorization {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .help("Needs sign-in")
            } else if account.unreadCount > 0 {
                Text("\(account.unreadCount)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct AccountNotice: View {
    let symbol: String
    let tint: Color
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct OpenInboxRow: View {
    let hiddenCount: Int
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Text("Open Inbox")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            if hiddenCount > 0 {
                Text("\(hiddenCount) more unread")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

private struct MessageRow: View {
    let message: EmailMessage
    let onOpen: () -> Void
    let onMarkAsRead: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(message.displayFrom)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(relativeTime)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if !message.displaySnippet.isEmpty {
                        Text(message.displaySnippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Gmail")

            Button(action: onMarkAsRead) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help("Mark as read")
            .accessibilityLabel("Mark as read")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open in Gmail", action: onOpen)
            Button("Mark as Read", action: onMarkAsRead)
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: message.internalDate, relativeTo: Date())
    }
}
