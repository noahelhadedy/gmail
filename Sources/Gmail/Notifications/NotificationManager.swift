import Foundation
import UserNotifications

protocol NotificationDispatching: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class NotificationManager: PollingNotifying {
    private let dispatcher: NotificationDispatching
    private let isEnabled: @Sendable () -> Bool

    init(
        dispatcher: NotificationDispatching = SystemNotificationDispatcher(),
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.dispatcher = dispatcher
        self.isEnabled = isEnabled
    }

    func requestAuthorization() async {
        do {
            _ = try await dispatcher.requestAuthorization(options: [.alert, .sound])
        } catch {
            // Silent failure; user can re-grant via System Settings.
        }
    }

    /// One banner per message. The subtitle names the receiving account so it's
    /// clear which inbox the mail landed in, and the click URL opens that account.
    nonisolated func notifyNewMessages(_ messages: [EmailMessage], account: String) async {
        await notifyNewMessages(messages, account: account) { message in
            Self.gmailURL(email: account, threadId: message.threadId)
        }
    }

    nonisolated func notifyNewMessages(
        _ messages: [EmailMessage],
        account: String,
        openURL: @escaping @Sendable (EmailMessage) -> URL
    ) async {
        guard !account.isEmpty, isEnabled() else { return }
        for message in messages {
            let content = UNMutableNotificationContent()
            content.title = message.from.isEmpty ? "New mail" : message.displayFrom
            content.subtitle = account
            content.body = message.subject.isEmpty ? "(no subject)" : message.subject
            content.threadIdentifier = account
            content.userInfo = [
                "messageId": message.id,
                "account": account,
                "url": openURL(message).absoluteString
            ]
            let request = UNNotificationRequest(
                identifier: "\(account)/\(message.id)",
                content: content,
                trigger: nil
            )
            try? await dispatcher.add(request)
        }
    }

    nonisolated static func gmailURL(email: String, threadId: String) -> URL {
        GmailWebURL.thread(email: email, threadId: threadId)
    }
}

struct SystemNotificationDispatcher: NotificationDispatching {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}
