import Foundation

struct StoredAccount: Codable, Equatable, Sendable {
    let email: String
    let colorIndex: Int
    var provider: MailProvider
    /// Zoho only: the data center the account lives in.
    var dataCenter: ZohoDataCenter?

    init(email: String, colorIndex: Int, provider: MailProvider = .gmail, dataCenter: ZohoDataCenter? = nil) {
        self.email = email
        self.colorIndex = colorIndex
        self.provider = provider
        self.dataCenter = dataCenter
    }

    // Accounts saved before Zoho support have no provider key: they are Gmail.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        provider = try container.decodeIfPresent(MailProvider.self, forKey: .provider) ?? .gmail
        dataCenter = try container.decodeIfPresent(ZohoDataCenter.self, forKey: .dataCenter)
    }
}

/// Persists the ordered list of signed-in accounts in UserDefaults. Tokens
/// never live here; they stay in Keychain keyed by the same email.
struct AccountStore {
    static let accountsKey = "accounts.list"
    /// Number of distinct dot colors in AccountColor. New accounts take the
    /// lowest index not already used, wrapping once every color is taken.
    static let colorCount = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [StoredAccount] {
        if let data = defaults.data(forKey: Self.accountsKey),
           let accounts = try? JSONDecoder().decode([StoredAccount].self, from: data) {
            return accounts
        }
        // One-time migration from the single-account build, which only stored
        // the last signed-in email.
        if let legacy = defaults.string(forKey: AuthService.lastEmailDefaultsKey), !legacy.isEmpty {
            let migrated = [StoredAccount(email: legacy, colorIndex: 0)]
            save(migrated)
            return migrated
        }
        return []
    }

    /// Adds the account if it's new and returns its stored entry. Re-adding an
    /// existing email (any case) returns the existing entry unchanged.
    @discardableResult
    func add(email: String, provider: MailProvider = .gmail, dataCenter: ZohoDataCenter? = nil) -> StoredAccount {
        var accounts = load()
        if let existing = accounts.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            return existing
        }
        let account = StoredAccount(
            email: email,
            colorIndex: Self.nextColorIndex(for: accounts),
            provider: provider,
            dataCenter: dataCenter
        )
        accounts.append(account)
        save(accounts)
        return account
    }

    func remove(email: String) {
        let accounts = load().filter { $0.email.caseInsensitiveCompare(email) != .orderedSame }
        save(accounts)
    }

    static func nextColorIndex(for accounts: [StoredAccount]) -> Int {
        let used = Set(accounts.map(\.colorIndex))
        if let free = (0..<colorCount).first(where: { !used.contains($0) }) {
            return free
        }
        return accounts.count % colorCount
    }

    private func save(_ accounts: [StoredAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
    }
}
