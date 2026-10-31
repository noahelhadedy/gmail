import XCTest
@testable import Gmail

/// Fixtures follow the shapes in Zoho's Mail API docs (accounts, folders,
/// messages/view) and a real response from a free-plan mailbox where the
/// primary address and an alias differ and several custom folders also have
/// folderType "Inbox".
final class ZohoAPIClientTests: XCTestCase {
    private var client: ZohoAPIClient!
    private let baseURL = URL(string: "https://mail.zoho.test/api")!

    override func setUp() {
        super.setUp()
        client = ZohoAPIClient(baseURL: baseURL, urlSession: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    static let accountsJSON = """
    {
      "status": {"code": 200, "description": "success"},
      "data": [{
        "accountId": "4994274000000008002",
        "isDefaultAccount": true,
        "type": "ZOHO_ACCOUNT",
        "mailboxAddress": "noah@designbookmark.com",
        "primaryEmailAddress": "noah@designbookmark.com",
        "emailAddress": [
          {"isAlias": true, "isPrimary": false, "mailId": "hello@designbookmark.com", "isConfirmed": true},
          {"isAlias": false, "isPrimary": true, "mailId": "noah@designbookmark.com", "isConfirmed": true},
          {"isAlias": true, "isPrimary": false, "mailId": "support@designbookmark.com", "isConfirmed": true}
        ]
      }]
    }
    """

    static let foldersJSON = """
    {
      "status": {"code": 200, "description": "success"},
      "data": [
        {"path": "/Drafts", "folderName": "Drafts", "folderType": "Drafts", "folderId": "4994274000000008009"},
        {"path": "/Newsletter", "folderName": "Newsletter", "folderType": "Inbox", "folderId": "4994274000000009006"},
        {"path": "/Inbox", "folderName": "Inbox", "folderType": "Inbox", "folderId": "4994274000000008008"},
        {"path": "/DMARC", "folderName": "DMARC", "folderType": "Inbox", "folderId": "4994274000000025001"}
      ]
    }
    """

    static let messagesJSON = """
    {
      "status": {"code": 200, "description": "success"},
      "data": [
        {
          "summary": "Hello Sent using Zoho Mail",
          "sentDateInGMT": "1709856390000",
          "calendarType": 0,
          "subject": "Older one",
          "messageId": "1709876190693100009",
          "flagid": "info",
          "status2": "0",
          "priority": "3",
          "hasInline": "false",
          "toAddress": "\\"rebecca\\"<rebecca@zylker.com>",
          "folderId": "9000000002014",
          "ccAddress": "Not Provided",
          "hasAttachment": "0",
          "size": "873",
          "sender": "test csez",
          "receivedTime": "1709876190649",
          "fromAddress": "paula@zyiker.com",
          "status": "0"
        },
        {
          "summary": "Tom &amp; Jerry&#39;s order",
          "sentDateInGMT": "1709856410000",
          "calendarType": 0,
          "subject": "Test",
          "messageId": "1709876210189100007",
          "threadCount": "0",
          "flagid": "flag_not_set",
          "status2": "0",
          "priority": "3",
          "hasInline": "false",
          "toAddress": "\\"rebecca\\"<rebecca@zylker.com>",
          "folderId": "9000000002014",
          "ccAddress": "Not Provided",
          "threadId": "1709876209452100005",
          "hasAttachment": "0",
          "size": "873",
          "sender": "",
          "receivedTime": "1709876210144",
          "fromAddress": "paula@zyiker.com",
          "status": "0"
        }
      ]
    }
    """

    func testGetAccountParsesIdPrimaryAndAliases() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/accounts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Zoho-oauthtoken tok")
            return (Self.ok(request), Data(Self.accountsJSON.utf8))
        }
        let info = try await client.getAccount(accessToken: "tok")
        XCTAssertEqual(info.accountId, "4994274000000008002")
        XCTAssertEqual(info.primaryEmail, "noah@designbookmark.com")
        XCTAssertEqual(info.addresses.count, 3)
    }

    func testDisplayEmailPrefersMatchingAliasElsePrimary() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.accountsJSON.utf8)) as? [String: Any])
        let info = try ZohoAPIClient.parseAccount(json)
        XCTAssertEqual(info.displayEmail(preferring: "Hello@DesignBookmark.com"), "hello@designbookmark.com")
        XCTAssertEqual(info.displayEmail(preferring: "someone@else.com"), "noah@designbookmark.com")
        XCTAssertEqual(info.displayEmail(preferring: nil), "noah@designbookmark.com")
    }

    func testAccountDataAsSingleObjectIsAccepted() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"status":{"code":200},"data":{"accountId":2560636000000008002,"primaryEmailAddress":"rebecca@zylker.com","mailboxAddress":"rebecca@zylker.com"}}
        """.utf8)) as? [String: Any])
        let info = try ZohoAPIClient.parseAccount(json)
        XCTAssertEqual(info.accountId, "2560636000000008002")
        XCTAssertEqual(info.addresses, [])
    }

    func testInboxFolderIgnoresCustomFoldersTypedInbox() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/accounts/42/folders")
            return (Self.ok(request), Data(Self.foldersJSON.utf8))
        }
        let id = try await client.inboxFolderId(accessToken: "tok", accountId: "42")
        XCTAssertEqual(id, "4994274000000008008")
    }

    func testListUnreadBuildsQueryAndDecodesMessagesNewestFirst() async throws {
        MockURLProtocol.setHandler { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            XCTAssertEqual(request.url?.path, "/api/accounts/42/messages/view")
            XCTAssertEqual(value("folderId"), "F1")
            XCTAssertEqual(value("status"), "unread")
            XCTAssertEqual(value("limit"), "200")
            XCTAssertEqual(value("sortBy"), "date")
            XCTAssertEqual(value("sortorder"), "false")
            return (Self.ok(request), Data(Self.messagesJSON.utf8))
        }
        let messages = try await client.listUnread(accessToken: "tok", accountId: "42", folderId: "F1", limit: 999)

        XCTAssertEqual(messages.map(\.id), ["1709876210189100007", "1709876190693100009"])
        let newest = messages[0]
        XCTAssertEqual(newest.threadId, "1709876209452100005")
        XCTAssertEqual(newest.from, "paula@zyiker.com")
        XCTAssertEqual(newest.displayFrom, "paula@zyiker.com")
        XCTAssertEqual(newest.displaySnippet, "Tom & Jerry's order")
        XCTAssertEqual(newest.internalDate, Date(timeIntervalSince1970: 1709876210.144))
        let older = messages[1]
        XCTAssertEqual(older.threadId, older.id, "no threadId falls back to the message id")
        XCTAssertEqual(older.displayFrom, "test csez")
        XCTAssertEqual(older.subject, "Older one")
    }

    func testEmptyInboxDecodesToNoMessages() async throws {
        MockURLProtocol.setHandler { request in
            (Self.ok(request), Data(#"{"status":{"code":200,"description":"success"},"data":[]}"#.utf8))
        }
        let messages = try await client.listUnread(accessToken: "tok", accountId: "42", folderId: "F1", limit: 20)
        XCTAssertTrue(messages.isEmpty)
    }

    func testMarkAsReadSendsPutWithNumericIds() async throws {
        MockURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/accounts/42/updatemessage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Zoho-oauthtoken tok")
            let body = request.httpBodyStreamData() ?? request.httpBody ?? Data()
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("\"markAsRead\""), text)
            XCTAssertTrue(text.contains("1709876210189100007"), text)
            XCTAssertFalse(text.contains("\"1709876210189100007\""), "ids must be numbers: \(text)")
            return (Self.ok(request), Data(#"{"status":{"code":200,"description":"success"}}"#.utf8))
        }
        try await client.markAsRead(accessToken: "tok", accountId: "42", messageId: "1709876210189100007")
    }

    func testHTTPErrorsMapToAppErrors() async {
        let cases: [(Int, AppError)] = [
            (401, .api(.unauthorized)),
            (404, .api(.notFound)),
            (429, .api(.rateLimited(retryAfter: nil))),
            (500, .api(.serverError(status: 500)))
        ]
        for (status, expected) in cases {
            MockURLProtocol.setHandler { request in
                (Self.response(request, status: status), Data("{}".utf8))
            }
            do {
                _ = try await client.getAccount(accessToken: "tok")
                XCTFail("expected \(status) to throw")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
        }
    }

    func testErrorStatusInsideHTTP200BodyIsAnError() async {
        MockURLProtocol.setHandler { request in
            (Self.ok(request), Data(#"{"status":{"code":401,"description":"Invalid"},"data":{"errorCode":"INVALID_OAUTHTOKEN"}}"#.utf8))
        }
        do {
            _ = try await client.getAccount(accessToken: "tok")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.unauthorized))
        }
    }

    func testGarbageBodyIsMalformed() async {
        MockURLProtocol.setHandler { request in (Self.ok(request), Data("<html>".utf8)) }
        do {
            _ = try await client.getAccount(accessToken: "tok")
            XCTFail("expected malformed")
        } catch {
            XCTAssertEqual(error as? AppError, .api(.malformedResponse))
        }
    }

    func testDataCenterBaseURL() {
        XCTAssertEqual(ZohoDataCenter.com.mailHost, "mail.zoho.com")
        XCTAssertEqual(ZohoDataCenter.eu.accountsHost, "accounts.zoho.eu")
        XCTAssertEqual(ZohoDataCenter.comAu.mailHost, "mail.zoho.com.au")
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse { response(request, status: 200) }

    private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

extension URLRequest {
    /// URLSession turns httpBody into a stream before URLProtocol sees it.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
