import XCTest
@testable import Gmail

final class GmailAPIClientTests: XCTestCase {
    private var session: URLSession!
    private var client: GmailAPIClient!
    private let baseURL = URL(string: "https://gmail.test/gmail/v1/users/me")!

    override func setUp() {
        super.setUp()
        session = MockURLProtocol.makeSession()
        client = GmailAPIClient(urlSession: session, baseURL: baseURL)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testGetProfileParsesEmailAndHistoryId() async throws {
        MockURLProtocol.setHandler { _ in
            let body = """
            {
              "emailAddress": "alice@example.com",
              "messagesTotal": 1234,
              "historyId": "987654"
            }
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let profile = try await client.getProfile(accessToken: "token")

        XCTAssertEqual(profile.emailAddress, "alice@example.com")
        XCTAssertEqual(profile.historyId, "987654")
        XCTAssertEqual(profile.messagesTotal, 1234)
    }

    func testListUnreadMessagesParsesIdsAndEstimate() async throws {
        MockURLProtocol.setHandler { _ in
            let body = """
            {
              "messages": [{"id":"m1"},{"id":"m2"}],
              "resultSizeEstimate": 2
            }
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let response = try await client.listUnreadMessages(accessToken: "tok", maxResults: 20)

        XCTAssertEqual(response.messageIds, ["m1", "m2"])
        XCTAssertEqual(response.resultSizeEstimate, 2)
    }

    func testListUnreadMessagesHandlesEmptyList() async throws {
        MockURLProtocol.setHandler { _ in
            let body = """
            {"resultSizeEstimate": 0}
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let response = try await client.listUnreadMessages(accessToken: "tok", maxResults: 20)

        XCTAssertEqual(response.messageIds, [])
        XCTAssertEqual(response.resultSizeEstimate, 0)
    }

    func testGetMessageMetadataExtractsHeaders() async throws {
        MockURLProtocol.setHandler { _ in
            let body = """
            {
              "id": "m1",
              "threadId": "t1",
              "internalDate": "1700000000000",
              "snippet": "hi there",
              "payload": {
                "headers": [
                  {"name":"From","value":"Alice <alice@example.com>"},
                  {"name":"Subject","value":"Hello"},
                  {"name":"Date","value":"..."}
                ]
              }
            }
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let message = try await client.getMessageMetadata(accessToken: "tok", id: "m1")

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.threadId, "t1")
        XCTAssertEqual(message.from, "Alice <alice@example.com>")
        XCTAssertEqual(message.subject, "Hello")
        XCTAssertEqual(message.internalDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(message.snippet, "hi there")
    }

    func testGetInboxUnreadCountReturnsMessagesUnread() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertTrue(
                request.url?.path.hasSuffix("/labels/INBOX") ?? false,
                "Should hit labels/INBOX endpoint"
            )
            let body = """
            {"id":"INBOX","name":"INBOX","messagesTotal":5000,"messagesUnread":237,"threadsUnread":120}
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let count = try await client.getInboxUnreadCount(accessToken: "tok")

        XCTAssertEqual(count, 237)
    }

    func testGetInboxUnreadCountReturnsZeroWhenFieldMissing() async throws {
        MockURLProtocol.setHandler { _ in
            let body = """
            {"id":"INBOX","name":"INBOX"}
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let count = try await client.getInboxUnreadCount(accessToken: "tok")

        XCTAssertEqual(count, 0)
    }

    func testListHistoryParsesAllChangeTypes() async throws {
        MockURLProtocol.setHandler { _ in
            let body = """
            {
              "historyId": "1001",
              "history": [
                {
                  "messagesAdded": [{"message":{"id":"m1","labelIds":["INBOX","UNREAD"]}}],
                  "messagesDeleted": [{"message":{"id":"m2","labelIds":["INBOX"]}}],
                  "labelsAdded": [{"message":{"id":"m3"},"labelIds":["INBOX","UNREAD"]}],
                  "labelsRemoved": [{"message":{"id":"m4"},"labelIds":["UNREAD"]}]
                }
              ]
            }
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        let response = try await client.listHistory(accessToken: "tok", startHistoryId: "1000")

        XCTAssertEqual(response.historyId, "1001")
        XCTAssertEqual(response.changes, [
            .messageAdded(id: "m1", labelIds: ["INBOX", "UNREAD"]),
            .messageDeleted(id: "m2", labelIds: ["INBOX"]),
            .labelAdded(messageId: "m3", label: "INBOX"),
            .labelAdded(messageId: "m3", label: "UNREAD"),
            .labelRemoved(messageId: "m4", label: "UNREAD")
        ])
    }

    func testListHistoryReturns404AsHistoryExpired() async {
        MockURLProtocol.setHandler { request in
            (Self.status(404, url: request.url!), Data())
        }

        do {
            _ = try await client.listHistory(accessToken: "tok", startHistoryId: "stale")
            XCTFail("expected error")
        } catch AppError.api(.historyExpired) {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testUnauthorizedSurfacesAsAPIError() async {
        MockURLProtocol.setHandler { request in
            (Self.status(401, url: request.url!), Data())
        }

        do {
            _ = try await client.getProfile(accessToken: "stale")
            XCTFail("expected unauthorized")
        } catch AppError.api(.unauthorized) {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testRateLimitedSurfacesRetryAfter() async {
        MockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "30"]
            )!
            return (response, Data())
        }

        do {
            _ = try await client.getProfile(accessToken: "tok")
            XCTFail("expected rate limit")
        } catch AppError.api(.rateLimited(let retryAfter)) {
            XCTAssertEqual(retryAfter, 30)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testServerError5xxSurfacesStatus() async {
        MockURLProtocol.setHandler { request in
            (Self.status(503, url: request.url!), Data())
        }

        do {
            _ = try await client.getProfile(accessToken: "tok")
            XCTFail("expected server error")
        } catch AppError.api(.serverError(let status)) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testMalformedResponseSurfaces() async {
        MockURLProtocol.setHandler { request in
            (Self.ok(), "<html>not json</html>".data(using: .utf8)!)
        }

        do {
            _ = try await client.getProfile(accessToken: "tok")
            XCTFail("expected malformed")
        } catch AppError.api(.malformedResponse) {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testNetworkErrorMapsToNetworkAppError() async {
        MockURLProtocol.setHandler { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.getProfile(accessToken: "tok")
            XCTFail("expected network error")
        } catch AppError.network {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testRequestIncludesBearerToken() async throws {
        let captured = Captured()
        MockURLProtocol.setHandler { request in
            captured.request = request
            let body = """
            {"emailAddress":"a@b.c","historyId":"1","messagesTotal":0}
            """.data(using: .utf8)!
            return (Self.ok(), body)
        }

        _ = try await client.getProfile(accessToken: "secret-token")

        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-token"
        )
    }

    func testMarkAsReadPostsModifyRemovingUnread() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"id":"m1","labelIds":["INBOX"]}"#.utf8))
        }

        try await client.markAsRead(accessToken: "tok", id: "m1")

        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/messages/m1/modify") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    private static func ok() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://gmail.test/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func status(_ code: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class Captured: @unchecked Sendable {
    var request: URLRequest?
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func record(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
}
