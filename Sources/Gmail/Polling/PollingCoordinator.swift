import Foundation

enum PollingState: Equatable, Sendable {
    case idle
    case polling
    case paused(PollingPauseReason)
    case backoff(until: Date)
}

enum PollingPauseReason: Equatable, Sendable {
    case popoverOpen
    case network
    case userPaused
}

protocol PollingNotifying: Sendable {
    func notifyNewMessages(_ messages: [EmailMessage], account: String) async
    /// Same, but the banner opens `openURL(message)` (non-Gmail providers).
    func notifyNewMessages(
        _ messages: [EmailMessage],
        account: String,
        openURL: @escaping @Sendable (EmailMessage) -> URL
    ) async
}

extension PollingNotifying {
    func notifyNewMessages(
        _ messages: [EmailMessage],
        account: String,
        openURL: @escaping @Sendable (EmailMessage) -> URL
    ) async {
        await notifyNewMessages(messages, account: account)
    }
}

/// Polls one Google account (Gmail provider). AccountManager owns one coordinator per account,
/// each with its own scheduler, AuthService and history pointer, so a revoked
/// or failing account never stalls the others.
@MainActor
final class PollingCoordinator {
    private(set) var state: PollingState = .idle
    var interval: TimeInterval = 60
    /// Runs after every tick, whatever its outcome.
    var onTickFinished: (@MainActor () -> Void)?

    let account: AccountState
    private let auth: AuthService
    private let api: GmailAPIClienting
    private let scheduler: PollScheduling
    private let notifier: PollingNotifying?
    private let now: @Sendable () -> Date
    private let userDefaults: UserDefaults

    init(
        account: AccountState,
        auth: AuthService,
        api: GmailAPIClienting,
        scheduler: PollScheduling,
        notifier: PollingNotifying? = nil,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.auth = auth
        self.api = api
        self.scheduler = scheduler
        self.notifier = notifier
        self.userDefaults = userDefaults
        self.now = now
    }

    static func historyIdKey(for email: String) -> String { "lastHistoryId.\(email.lowercased())" }
    static func fetchTimeKey(for email: String) -> String { "lastFetchTime.\(email.lowercased())" }

    var lastHistoryId: String? {
        get { userDefaults.string(forKey: Self.historyIdKey(for: account.email)) }
        set { userDefaults.set(newValue, forKey: Self.historyIdKey(for: account.email)) }
    }

    var lastFetchTime: Date {
        get {
            if let interval = userDefaults.object(forKey: Self.fetchTimeKey(for: account.email)) as? TimeInterval {
                return Date(timeIntervalSince1970: interval)
            }
            return .distantPast
        }
        set { userDefaults.set(newValue.timeIntervalSince1970, forKey: Self.fetchTimeKey(for: account.email)) }
    }

    /// Drops the per-account history pointer so the next tick does a full reload.
    func clearPersistedState() {
        userDefaults.removeObject(forKey: Self.historyIdKey(for: account.email))
        userDefaults.removeObject(forKey: Self.fetchTimeKey(for: account.email))
    }

    func start() async {
        guard auth.session != nil else {
            state = .idle
            return
        }
        await beginPolling()
    }

    func stop() async {
        state = .idle
        await scheduler.invalidate()
    }

    func popoverOpened() async {
        guard case .polling = state else { return }
        state = .paused(.popoverOpen)
        await scheduler.invalidate()
        await performTick()
    }

    func popoverClosed() async {
        guard case .paused(.popoverOpen) = state else { return }
        await tickAndReschedule()
    }

    func networkChanged(to connection: ConnectionState) async {
        switch (state, connection) {
        case (_, .offline):
            if state != .idle {
                state = .paused(.network)
                await scheduler.invalidate()
            }
        case (.paused(.network), .online):
            await tickAndReschedule()
        default:
            break
        }
    }

    func performTick() async {
        defer { onTickFinished?() }
        guard auth.session != nil else {
            // Tokens are gone (revoked, or missing after relaunch): nothing to poll
            // until the user signs this account in again.
            account.authState = .needsReauthorization
            return
        }
        account.loadState = .loading
        do {
            try await fetch()
            account.loadState = .loaded
            account.lastError = nil
            account.authState = .signedIn(email: account.email)
            lastFetchTime = now()
        } catch let error as AppError {
            handle(error)
        } catch {
            account.loadState = .failed(.api(.malformedResponse))
            account.lastError = .api(.malformedResponse)
        }
    }

    /// Marks one message read in Gmail, then drops it from the list right away
    /// so the popover and menu bar count update without waiting for the next poll.
    func markAsRead(_ message: EmailMessage) async {
        do {
            let token = try await auth.freshAccessToken()
            try await api.markAsRead(accessToken: token, id: message.id)
            if account.emails.contains(where: { $0.id == message.id }) {
                account.emails.removeAll { $0.id == message.id }
                account.unreadCount = max(0, account.unreadCount - 1)
            }
            if let count = try? await api.getInboxUnreadCount(accessToken: token) {
                account.unreadCount = count
            }
        } catch let error as AppError {
            handle(error)
        } catch {
            account.lastError = .api(.malformedResponse)
        }
    }

    private func beginPolling() async {
        state = .polling
        await scheduler.schedule(interval: interval) { [weak self] in
            await self?.performTick()
        }
    }

    private func tickAndReschedule() async {
        state = .polling
        await performTick()
        if case .polling = state {
            await scheduler.schedule(interval: interval) { [weak self] in
                await self?.performTick()
            }
        }
    }

    private func fetch() async throws {
        let token = try await auth.freshAccessToken()
        if let historyId = lastHistoryId {
            try await fetchIncremental(token: token, since: historyId)
        } else {
            try await fetchInitial(token: token)
        }
    }

    private func fetchInitial(token: String) async throws {
        let profile = try await api.getProfile(accessToken: token)
        if auth.session?.email == nil {
            try? auth.attachEmail(profile.emailAddress)
        }

        let list = try await api.listUnreadMessages(accessToken: token, maxResults: 20)
        var messages: [EmailMessage] = []
        for id in list.messageIds {
            do {
                let message = try await api.getMessageMetadata(accessToken: token, id: id)
                messages.append(message)
            } catch AppError.api(.notFound) {
                // Message disappeared between list and get; skip.
                continue
            }
        }
        account.emails = messages.sorted { $0.internalDate > $1.internalDate }
        // labels.get(INBOX).messagesUnread is the authoritative total. resultSizeEstimate
        // from messages.list is bounded by maxResults across responses, so it caps at 20.
        account.unreadCount = (try? await api.getInboxUnreadCount(accessToken: token))
            ?? list.resultSizeEstimate
        lastHistoryId = profile.historyId
    }

    private func fetchIncremental(token: String, since historyId: String) async throws {
        // Defense-in-depth: if we somehow got here without an email on the session
        // (e.g., a stale historyId from a previous binary version), fall back to the
        // initial path so attachEmail runs and authState transitions to .signedIn.
        if auth.session?.email == nil {
            lastHistoryId = nil
            try await fetchInitial(token: token)
            return
        }

        let response: HistoryResponse
        do {
            response = try await api.listHistory(accessToken: token, startHistoryId: historyId)
        } catch AppError.api(.historyExpired) {
            // Normal flow: full reload then suppress notifications for old mail.
            lastHistoryId = nil
            try await fetchInitial(token: token)
            return
        }

        var addedIds: [String] = []
        var removedIds: Set<String> = []
        for change in response.changes {
            switch change {
            case .messageAdded(let id, let labelIds):
                // Only surface messages that arrived in INBOX; ignore sent/draft/spam events.
                if labelIds.contains("INBOX") { addedIds.append(id) }
            case .messageDeleted(let id, let labelIds):
                // Only react to deletions of inbox messages; harmless no-op for others.
                if labelIds.contains("INBOX") { removedIds.insert(id) }
            case .labelAdded(let id, let label):
                if label == "INBOX" { addedIds.append(id) }
            case .labelRemoved(let id, let label):
                if label == "INBOX" || label == "UNREAD" {
                    removedIds.insert(id)
                }
            }
        }

        if !addedIds.isEmpty {
            var newMessages: [EmailMessage] = []
            for id in Array(Set(addedIds)) {
                do {
                    let message = try await api.getMessageMetadata(accessToken: token, id: id)
                    newMessages.append(message)
                } catch AppError.api(.notFound) {
                    continue
                }
            }
            await notifier?.notifyNewMessages(newMessages, account: account.email)
            account.emails = (newMessages + account.emails)
                .reduce(into: [EmailMessage]()) { acc, message in
                    if !acc.contains(where: { $0.id == message.id }) { acc.append(message) }
                }
                .sorted { $0.internalDate > $1.internalDate }
        }
        if !removedIds.isEmpty {
            account.emails.removeAll { removedIds.contains($0.id) }
        }
        // Re-query the authoritative INBOX unread count on every poll (1 quota unit),
        // so the menu bar total stays right even for changes history doesn't flag.
        // Falls back to the previous in-memory count if the call fails — better stale
        // than wrong (collapsing to emails.count would clamp to the visible cap of 20).
        if let count = try? await api.getInboxUnreadCount(accessToken: token) {
            account.unreadCount = count
        }
        lastHistoryId = response.historyId
    }

    private func handle(_ error: AppError) {
        switch error {
        case .api(.unauthorized):
            // 401 shouldn't reach here normally — AuthService refreshes proactively.
            // If it does, mark as needing reauthorization.
            account.authState = .needsReauthorization
            account.lastError = error
        case .auth(.refreshTokenInvalid):
            account.authState = .needsReauthorization
            account.lastError = error
        case .api(.rateLimited(let retryAfter)):
            let backoffUntil = now().addingTimeInterval(retryAfter ?? 60)
            state = .backoff(until: backoffUntil)
            account.lastError = error
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((retryAfter ?? 60) * 1_000_000_000))
                await self?.recoverFromBackoff()
            }
        case .network:
            state = .paused(.network)
            account.lastError = error
        default:
            account.lastError = error
        }
        account.loadState = .failed(error)
    }

    private func recoverFromBackoff() async {
        guard case .backoff = state else { return }
        await beginPolling()
    }
}
