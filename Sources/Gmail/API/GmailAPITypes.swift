import Foundation

struct GmailProfile: Sendable, Equatable {
    let emailAddress: String
    let historyId: String
    let messagesTotal: Int
}

struct MessageListResponse: Sendable, Equatable {
    let messageIds: [String]
    let resultSizeEstimate: Int
}

struct HistoryResponse: Sendable, Equatable {
    let historyId: String
    let changes: [HistoryChange]
}

enum HistoryChange: Sendable, Equatable {
    // labelIds = the labels the message had at the time of the event (from the history record).
    // Used to determine inbox relevance without a separate metadata fetch.
    case messageAdded(id: String, labelIds: [String])
    case messageDeleted(id: String, labelIds: [String])
    case labelAdded(messageId: String, label: String)
    case labelRemoved(messageId: String, label: String)
}

protocol GmailAPIClienting: Sendable {
    func getProfile(accessToken: String) async throws -> GmailProfile
    func listUnreadMessages(accessToken: String, maxResults: Int) async throws -> MessageListResponse
    func getMessageMetadata(accessToken: String, id: String) async throws -> EmailMessage
    func listHistory(accessToken: String, startHistoryId: String) async throws -> HistoryResponse
    /// Returns the authoritative unread count for the INBOX label.
    /// Costs 1 quota unit. The list endpoints' resultSizeEstimate caps at maxResults
    /// across responses, so we never rely on it for the visible total.
    func getInboxUnreadCount(accessToken: String) async throws -> Int
    /// Removes the UNREAD label from one message (messages.modify, 5 quota units).
    func markAsRead(accessToken: String, id: String) async throws
}
