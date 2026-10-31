import Foundation

final class GmailAPIClient: GmailAPIClienting, @unchecked Sendable {
    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    private let urlSession: URLSession
    private let baseURL: URL

    init(urlSession: URLSession = .shared, baseURL: URL = GmailAPIClient.baseURL) {
        self.urlSession = urlSession
        self.baseURL = baseURL
    }

    func getProfile(accessToken: String) async throws -> GmailProfile {
        let request = makeRequest(path: "profile", queryItems: [], accessToken: accessToken)
        let json = try await sendJSON(request)
        guard let email = json["emailAddress"] as? String,
              let historyId = json["historyId"] as? String else {
            throw AppError.api(.malformedResponse)
        }
        let messagesTotal = (json["messagesTotal"] as? Int) ?? 0
        return GmailProfile(
            emailAddress: email,
            historyId: historyId,
            messagesTotal: messagesTotal
        )
    }

    func listUnreadMessages(accessToken: String, maxResults: Int) async throws -> MessageListResponse {
        let request = makeRequest(
            path: "messages",
            queryItems: [
                URLQueryItem(name: "labelIds", value: "INBOX"),
                URLQueryItem(name: "q", value: "is:unread"),
                URLQueryItem(name: "maxResults", value: String(maxResults))
            ],
            accessToken: accessToken
        )
        let json = try await sendJSON(request)
        let messages = (json["messages"] as? [[String: Any]]) ?? []
        let ids = messages.compactMap { $0["id"] as? String }
        let estimate = (json["resultSizeEstimate"] as? Int) ?? ids.count
        return MessageListResponse(messageIds: ids, resultSizeEstimate: estimate)
    }

    func getMessageMetadata(accessToken: String, id: String) async throws -> EmailMessage {
        let request = makeRequest(
            path: "messages/\(id)",
            queryItems: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "Date")
            ],
            accessToken: accessToken
        )
        let json = try await sendJSON(request)
        return try Self.parseMessage(json)
    }

    func listHistory(accessToken: String, startHistoryId: String) async throws -> HistoryResponse {
        // No labelId filter here: Gmail filters by the message's *current* labels, so deleted/
        // archived messages (which no longer carry INBOX) would be excluded. We filter inbox-
        // relevant events client-side using the labelIds embedded in each history record.
        let request = makeRequest(
            path: "history",
            queryItems: [
                URLQueryItem(name: "startHistoryId", value: startHistoryId)
            ],
            accessToken: accessToken
        )
        let json = try await sendJSON(request)
        guard let historyId = json["historyId"] as? String else {
            throw AppError.api(.malformedResponse)
        }
        let history = (json["history"] as? [[String: Any]]) ?? []
        var changes: [HistoryChange] = []
        for record in history {
            for added in (record["messagesAdded"] as? [[String: Any]]) ?? [] {
                if let message = added["message"] as? [String: Any],
                   let id = message["id"] as? String {
                    let labelIds = message["labelIds"] as? [String] ?? []
                    changes.append(.messageAdded(id: id, labelIds: labelIds))
                }
            }
            for deleted in (record["messagesDeleted"] as? [[String: Any]]) ?? [] {
                if let message = deleted["message"] as? [String: Any],
                   let id = message["id"] as? String {
                    let labelIds = message["labelIds"] as? [String] ?? []
                    changes.append(.messageDeleted(id: id, labelIds: labelIds))
                }
            }
            for labelAdded in (record["labelsAdded"] as? [[String: Any]]) ?? [] {
                guard let message = labelAdded["message"] as? [String: Any],
                      let id = message["id"] as? String,
                      let labels = labelAdded["labelIds"] as? [String] else { continue }
                for label in labels {
                    changes.append(.labelAdded(messageId: id, label: label))
                }
            }
            for labelRemoved in (record["labelsRemoved"] as? [[String: Any]]) ?? [] {
                guard let message = labelRemoved["message"] as? [String: Any],
                      let id = message["id"] as? String,
                      let labels = labelRemoved["labelIds"] as? [String] else { continue }
                for label in labels {
                    changes.append(.labelRemoved(messageId: id, label: label))
                }
            }
        }
        return HistoryResponse(historyId: historyId, changes: changes)
    }

    func getInboxUnreadCount(accessToken: String) async throws -> Int {
        let request = makeRequest(path: "labels/INBOX", queryItems: [], accessToken: accessToken)
        let json = try await sendJSON(request)
        return (json["messagesUnread"] as? Int) ?? 0
    }

    /// Removes the UNREAD label from one message. Needs the gmail.modify scope.
    func markAsRead(accessToken: String, id: String) async throws {
        var request = makeRequest(path: "messages/\(id)/modify", queryItems: [], accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["removeLabelIds": ["UNREAD"]])
        _ = try await sendJSON(request)
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem],
        accessToken: String
    ) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
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
        try Self.checkStatus(http, request: request)
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.api(.malformedResponse)
        }
        return parsed
    }

    private static func checkStatus(_ http: HTTPURLResponse, request: URLRequest) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw AppError.api(.unauthorized)
        case 404:
            // history.list 在 historyId 过期时返回 404, 其它 404 也走相同路径让上层判断
            if request.url?.path.hasSuffix("/history") == true {
                throw AppError.api(.historyExpired)
            }
            throw AppError.api(.notFound)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw AppError.api(.rateLimited(retryAfter: retryAfter))
        case 500..<600:
            throw AppError.api(.serverError(status: http.statusCode))
        default:
            throw AppError.api(.serverError(status: http.statusCode))
        }
    }

    static func parseMessage(_ json: [String: Any]) throws -> EmailMessage {
        guard let id = json["id"] as? String,
              let threadId = json["threadId"] as? String else {
            throw AppError.api(.malformedResponse)
        }
        let internalDateMs: Int64
        if let value = json["internalDate"] as? String, let parsed = Int64(value) {
            internalDateMs = parsed
        } else if let value = json["internalDate"] as? Int64 {
            internalDateMs = value
        } else if let value = json["internalDate"] as? Int {
            internalDateMs = Int64(value)
        } else {
            internalDateMs = 0
        }
        let internalDate = Date(timeIntervalSince1970: TimeInterval(internalDateMs) / 1000)
        let snippet = json["snippet"] as? String

        var from = ""
        var subject = ""
        if let payload = json["payload"] as? [String: Any],
           let headers = payload["headers"] as? [[String: Any]] {
            for header in headers {
                guard let name = header["name"] as? String,
                      let value = header["value"] as? String else { continue }
                switch name.lowercased() {
                case "from": from = value
                case "subject": subject = value
                default: break
                }
            }
        }
        return EmailMessage(
            id: id,
            threadId: threadId,
            from: from,
            subject: subject,
            internalDate: internalDate,
            snippet: snippet
        )
    }
}
