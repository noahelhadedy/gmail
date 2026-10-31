import Foundation
import Observation

enum ConnectionState: Equatable {
    case unknown
    case online
    case offline
}

enum AuthState: Equatable {
    case signedOut
    case signedIn(email: String)
    case needsReauthorization
}

enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(AppError)
}

/// Everything the UI needs to know about one mail account. Each account is
/// polled by its own PollingCoordinator, so one account failing never touches
/// the others' state.
@MainActor
@Observable
final class AccountState: Identifiable {
    nonisolated let email: String
    let colorIndex: Int
    let provider: MailProvider
    let dataCenter: ZohoDataCenter?
    var emails: [EmailMessage] = []
    var unreadCount: Int = 0
    var authState: AuthState
    var loadState: LoadState = .idle
    var lastError: AppError?

    nonisolated var id: String { email }

    init(
        email: String,
        colorIndex: Int,
        authState: AuthState? = nil,
        provider: MailProvider = .gmail,
        dataCenter: ZohoDataCenter? = nil
    ) {
        self.email = email
        self.colorIndex = colorIndex
        self.provider = provider
        self.dataCenter = dataCenter
        self.authState = authState ?? .signedIn(email: email)
    }

    var needsReauthorization: Bool {
        authState == .needsReauthorization
    }

    /// Opens one message in the provider's web mail.
    func webURL(for message: EmailMessage) -> URL {
        switch provider {
        case .gmail: return GmailWebURL.thread(email: email, threadId: message.threadId)
        case .zoho: return ZohoWebURL.message(dataCenter: dataCenter ?? .com, messageId: message.id)
        }
    }

    var inboxURL: URL {
        switch provider {
        case .gmail: return GmailWebURL.inbox(email: email)
        case .zoho: return ZohoWebURL.inbox(dataCenter: dataCenter ?? .com)
        }
    }

    func reset() {
        emails = []
        unreadCount = 0
        loadState = .idle
        lastError = nil
    }
}

@MainActor
@Observable
final class AppState {
    var accounts: [AccountState] = []
    var connectionState: ConnectionState = .unknown
    /// False when the build has no OAuth client ID. The UI shows setup help
    /// instead of an "Add Account" button that can't work.
    var isConfigured: Bool = true
    /// True when the build has a Zoho OAuth client. Without it the UI hides
    /// every "Add Zoho Account" entry point.
    var isZohoConfigured: Bool = false

    /// Sum of every account's INBOX unread count. Accounts that need to sign in
    /// again keep their last known count until they are fixed or removed.
    var totalUnreadCount: Int {
        accounts.reduce(0) { $0 + $1.unreadCount }
    }

    /// Collapses per-account auth into one value for the menu bar icon: any
    /// account needing reauthorization wins, otherwise signed in if any exists.
    var aggregateAuthState: AuthState {
        if accounts.contains(where: \.needsReauthorization) { return .needsReauthorization }
        if let first = accounts.first { return .signedIn(email: first.email) }
        return .signedOut
    }

    var topPriorityError: AppError? {
        accounts.compactMap(\.lastError).max { $0.priority < $1.priority }
    }

    func account(for email: String) -> AccountState? {
        accounts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    func reset() {
        accounts = []
        connectionState = .unknown
    }
}
