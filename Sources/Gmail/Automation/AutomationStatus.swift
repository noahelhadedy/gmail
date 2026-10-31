import Foundation

/// Contents of accounts-status.json. Deliberately has no token fields: it only
/// reports which accounts exist and whether they work.
struct AutomationStatus: Codable, Equatable {
    enum State: String, Codable {
        case ok
        case needsReauth
        case error
    }

    struct Account: Codable, Equatable {
        let email: String
        let state: State
        let unreadCount: Int
        let lastError: String?
        /// Absent in files written before Zoho support; those accounts are Gmail.
        var provider: MailProvider? = nil
    }

    struct AddAccountResult: Codable, Equatable {
        /// The account that actually signed in (nil when the attempt failed).
        let email: String?
        let ok: Bool
        let error: String?
        let loginHint: String?
        let finishedAt: Date
        var provider: MailProvider? = nil
    }

    var updatedAt: Date
    var addAccountInProgress: Bool
    var accounts: [Account]
    var lastAddAccount: AddAccountResult?

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension AutomationStatus.Account {
    @MainActor
    init(_ account: AccountState) {
        email = account.email
        provider = account.provider
        unreadCount = account.unreadCount
        lastError = account.lastError.map { String(describing: $0) }
        if account.needsReauthorization {
            state = .needsReauth
        } else if account.lastError != nil {
            state = .error
        } else {
            state = .ok
        }
    }
}

/// Keeps accounts-status.json in sync with AppState.
@MainActor
final class AutomationStatusWriter {
    private let appState: AppState
    private let fileURL: URL
    private let now: () -> Date
    private(set) var lastAddAccount: AutomationStatus.AddAccountResult?
    var addAccountInProgress = false

    init(appState: AppState, fileURL: URL = AutomationFiles.status, now: @escaping () -> Date = Date.init) {
        self.appState = appState
        self.fileURL = fileURL
        self.now = now
        // Keep the last add-account result across relaunches.
        if let data = try? Data(contentsOf: fileURL),
           let previous = try? AutomationStatus.decoder().decode(AutomationStatus.self, from: data) {
            lastAddAccount = previous.lastAddAccount
        }
    }

    func snapshot() -> AutomationStatus {
        AutomationStatus(
            updatedAt: now(),
            addAccountInProgress: addAccountInProgress,
            accounts: appState.accounts.map(AutomationStatus.Account.init),
            lastAddAccount: lastAddAccount
        )
    }

    func recordAddAccount(email: String?, loginHint: String?, error: Error?, provider: MailProvider = .gmail) {
        lastAddAccount = AutomationStatus.AddAccountResult(
            email: email,
            ok: error == nil,
            error: error.map(Self.describe),
            loginHint: loginHint,
            finishedAt: now(),
            provider: provider
        )
        write()
    }

    func write() {
        guard let data = try? AutomationStatus.encoder().encode(snapshot()) else { return }
        try? AutomationFiles.writePrivate(data, to: fileURL)
    }

    static func describe(_ error: Error) -> String {
        if let appError = error as? AppError { return String(describing: appError) }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }
}
