import Foundation

struct ZohoAccountInfo: Equatable, Sendable {
    let accountId: String
    let primaryEmail: String
    /// Every address that delivers to this mailbox (aliases included).
    let addresses: [String]

    /// The address to show for the account: the one Noah signed in with when it
    /// belongs to this mailbox (e.g. an alias like hello@), else the primary.
    func displayEmail(preferring loginHint: String?) -> String {
        if let hint = loginHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty,
           let match = addresses.first(where: { $0.caseInsensitiveCompare(hint) == .orderedSame }) {
            return match
        }
        return primaryEmail
    }
}

protocol ZohoAPIClienting: Sendable {
    func getAccount(accessToken: String) async throws -> ZohoAccountInfo
    func inboxFolderId(accessToken: String, accountId: String) async throws -> String
    /// Newest first. `limit` is capped at 200 by Zoho.
    func listUnread(accessToken: String, accountId: String, folderId: String, limit: Int) async throws -> [EmailMessage]
    func markAsRead(accessToken: String, accountId: String, messageId: String) async throws
}

/// Zoho Mail REST API (https://www.zoho.com/mail/help/api/). Note the auth
/// header is `Zoho-oauthtoken`, not `Bearer`.
final class ZohoAPIClient: ZohoAPIClienting, @unchecked Sendable {
    /// Zoho caps messages/view at 200 per call.
    static let maxListLimit = 200

    private let urlSession: URLSession
    private let baseURL: URL

    init(dataCenter: ZohoDataCenter = .com, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.baseURL = URL(string: "https://\(dataCenter.mailHost)/api")!
    }

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.baseURL = baseURL
    }

    func getAccount(accessToken: String) async throws -> ZohoAccountInfo {
        let json = try await send(makeRequest(path: "accounts", accessToken: accessToken))
        return try Self.parseAccount(json)
    }

    func inboxFolderId(accessToken: String, accountId: String) async throws -> String {
        let json = try await send(makeRequest(path: "accounts/\(accountId)/folders", accessToken: accessToken))
        return try Self.parseInboxFolderId(json)
    }

    func listUnread(accessToken: String, accountId: String, folderId: String, limit: Int) async throws -> [EmailMessage] {
        let request = makeRequest(
            path: "accounts/\(accountId)/messages/view",
            queryItems: [
                URLQueryItem(name: "folderId", value: folderId),
                URLQueryItem(name: "status", value: "unread"),
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), Self.maxListLimit))),
                URLQueryItem(name: "sortBy", value: "date"),
                URLQueryItem(name: "sortorder", value: "false")
            ],
            accessToken: accessToken
        )
        return try Self.parseMessages(try await send(request))
    }

    func markAsRead(accessToken: String, accountId: String, messageId: String) async throws {
        var request = makeRequest(path: "accounts/\(accountId)/updatemessage", accessToken: accessToken)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Zoho wants numeric ids; fall back to the raw string if one isn't.
        let id: Any = Int64(messageId) ?? messageId
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": "markAsRead", "messageId": [id]])
        _ = try await send(request)
    }

    // MARK: Requests

    private func makeRequest(path: String, queryItems: [URLQueryItem] = [], accessToken: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Zoho-oauthtoken \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppError.network(.unknown(reason: error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppError.api(.malformedResponse)
        }
        try Self.checkStatus(http)
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.api(.malformedResponse)
        }
        // Zoho can also report failures in the body of an HTTP 200.
        if let status = parsed["status"] as? [String: Any], let code = status["code"] as? Int, code >= 400 {
            throw Self.error(forStatus: code, retryAfter: nil)
        }
        return parsed
    }

    private static func checkStatus(_ http: HTTPURLResponse) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        throw error(forStatus: http.statusCode, retryAfter: retryAfter)
    }

    private static func error(forStatus status: Int, retryAfter: TimeInterval?) -> AppError {
        switch status {
        case 401: return .api(.unauthorized)
        case 404: return .api(.notFound)
        case 429: return .api(.rateLimited(retryAfter: retryAfter))
        default: return .api(.serverError(status: status))
        }
    }

    // MARK: Parsing

    /// `GET /accounts` returns `data` as an array (one entry per mailbox).
    /// The default mailbox wins; a single-object `data` is accepted too.
    static func parseAccount(_ json: [String: Any]) throws -> ZohoAccountInfo {
        let entries: [[String: Any]]
        if let list = json["data"] as? [[String: Any]] {
            entries = list
        } else if let single = json["data"] as? [String: Any] {
            entries = [single]
        } else {
            throw AppError.api(.malformedResponse)
        }
        let entry = entries.first { ($0["isDefaultAccount"] as? Bool) == true } ?? entries.first
        guard let entry,
              let accountId = Self.string(entry["accountId"]),
              let primary = (entry["primaryEmailAddress"] as? String) ?? (entry["mailboxAddress"] as? String) else {
            throw AppError.api(.malformedResponse)
        }
        let addresses = (entry["emailAddress"] as? [[String: Any]] ?? []).compactMap { $0["mailId"] as? String }
        return ZohoAccountInfo(accountId: accountId, primaryEmail: primary, addresses: addresses)
    }

    /// Custom folders can also have `folderType` "Inbox", so match the real
    /// Inbox by path or name first and only then by type.
    static func parseInboxFolderId(_ json: [String: Any]) throws -> String {
        guard let folders = json["data"] as? [[String: Any]] else {
            throw AppError.api(.malformedResponse)
        }
        let inbox = folders.first { ($0["path"] as? String)?.lowercased() == "/inbox" }
            ?? folders.first { ($0["folderName"] as? String)?.lowercased() == "inbox" }
            ?? folders.first { ($0["folderType"] as? String)?.lowercased() == "inbox" }
        guard let id = inbox.flatMap({ Self.string($0["folderId"]) }) else {
            throw AppError.api(.malformedResponse)
        }
        return id
    }

    static func parseMessages(_ json: [String: Any]) throws -> [EmailMessage] {
        // No unread mail comes back as an empty (or missing) array.
        guard let list = json["data"] as? [[String: Any]] else {
            if json["data"] == nil || json["data"] is NSNull { return [] }
            throw AppError.api(.malformedResponse)
        }
        return list.compactMap(parseMessage)
            .sorted { $0.internalDate > $1.internalDate }
    }

    static func parseMessage(_ json: [String: Any]) -> EmailMessage? {
        guard let id = string(json["messageId"]) else { return nil }
        let name = (json["sender"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let address = (json["fromAddress"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let from: String
        switch (name.isEmpty, address.isEmpty) {
        case (false, false): from = "\(name) <\(address)>"
        case (true, false): from = address
        case (false, true): from = name
        case (true, true): from = ""
        }
        let millis = string(json["receivedTime"]).flatMap(Double.init)
            ?? string(json["sentDateInGMT"]).flatMap(Double.init)
            ?? 0
        let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmailMessage(
            id: id,
            threadId: string(json["threadId"]) ?? id,
            from: from,
            subject: (json["subject"] as? String) ?? "",
            internalDate: Date(timeIntervalSince1970: millis / 1000),
            snippet: (summary?.isEmpty ?? true) ? nil : summary
        )
    }

    /// Zoho sends ids as JSON strings in some endpoints and numbers in others.
    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
