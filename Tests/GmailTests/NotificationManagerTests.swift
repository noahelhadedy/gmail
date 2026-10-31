import XCTest
import UserNotifications
@testable import Gmail

@MainActor
final class NotificationManagerTests: XCTestCase {
    private var dispatcher: RecordingDispatcher!
    private var manager: NotificationManager!

    override func setUp() async throws {
        try await super.setUp()
        dispatcher = RecordingDispatcher()
        manager = NotificationManager(dispatcher: dispatcher)
    }

    func testGmailURLUsesAuthuserQueryParamForMultiAccount() {
        let url = NotificationManager.gmailURL(email: "alice@example.com", threadId: "abc123")
        XCTAssertEqual(
            url.absoluteString,
            "https://mail.google.com/mail/?authuser=alice@example.com#inbox/abc123"
        )
    }

    func testGmailURLOmitsAuthuserWhenEmailMissing() {
        let url = NotificationManager.gmailURL(email: "", threadId: "abc123")
        XCTAssertEqual(
            url.absoluteString,
            "https://mail.google.com/mail/#inbox/abc123"
        )
    }

    func testNotifySkipsWhenAccountMissing() async {
        await manager.notifyNewMessages([makeMessage(id: "m1", from: "A", subject: "S")], account: "")

        XCTAssertEqual(dispatcher.added.count, 0)
    }

    func testNotifySkipsWhenDisabledInSettings() async {
        let disabled = NotificationManager(dispatcher: dispatcher, isEnabled: { false })

        await disabled.notifyNewMessages([makeMessage(id: "m1", from: "A", subject: "S")], account: "alice@example.com")

        XCTAssertEqual(dispatcher.added.count, 0)
    }

    func testNotificationSubtitleNamesAccountAndURLTargetsIt() async {
        await manager.notifyNewMessages(
            [makeMessage(id: "m1", from: "Alice <alice@x.com>", subject: "Hi")],
            account: "hello@djectstudio.com"
        )

        let request = dispatcher.added.first!
        XCTAssertEqual(request.content.title, "Alice")
        XCTAssertEqual(request.content.subtitle, "hello@djectstudio.com")
        XCTAssertEqual(request.content.userInfo["account"] as? String, "hello@djectstudio.com")
        XCTAssertEqual(
            request.content.userInfo["url"] as? String,
            "https://mail.google.com/mail/?authuser=hello@djectstudio.com#inbox/t-m1"
        )
    }

    func testSameMessageIdInTwoAccountsGetsTwoNotifications() async {
        await manager.notifyNewMessages([makeMessage(id: "m1", from: "A", subject: "S")], account: "a@example.com")
        await manager.notifyNewMessages([makeMessage(id: "m1", from: "A", subject: "S")], account: "b@example.com")

        XCTAssertEqual(Set(dispatcher.added.map(\.identifier)).count, 2)
    }

    func testNotifyDispatchesOnePerMessage() async {
        await manager.notifyNewMessages([
            makeMessage(id: "m1", from: "Alice", subject: "Hi"),
            makeMessage(id: "m2", from: "Bob", subject: "Hey")
        ], account: "alice@example.com")

        XCTAssertEqual(dispatcher.added.map(\.identifier), ["alice@example.com/m1", "alice@example.com/m2"])
    }

    func testNotificationContentHasFromAndSubject() async {
        await manager.notifyNewMessages([
            makeMessage(id: "m1", from: "Alice", subject: "Hello world")
        ], account: "alice@example.com")

        let request = dispatcher.added.first!
        XCTAssertEqual(request.content.title, "Alice")
        XCTAssertEqual(request.content.body, "Hello world")
        XCTAssertEqual(request.content.userInfo["messageId"] as? String, "m1")
        XCTAssertEqual(
            request.content.userInfo["url"] as? String,
            "https://mail.google.com/mail/?authuser=alice@example.com#inbox/t-m1",
            "Notification URL must use authuser query param + threadId for reliable cross-account opening"
        )
    }

    func testNotificationFallsBackForEmptyHeaders() async {
        await manager.notifyNewMessages([
            makeMessage(id: "m1", from: "", subject: "")
        ], account: "alice@example.com")

        let request = dispatcher.added.first!
        XCTAssertEqual(request.content.title, "New mail")
        XCTAssertEqual(request.content.body, "(no subject)")
    }

    private func makeMessage(id: String, from: String, subject: String) -> EmailMessage {
        EmailMessage(
            id: id,
            threadId: "t-\(id)",
            from: from,
            subject: subject,
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: nil
        )
    }
}

private final class RecordingDispatcher: NotificationDispatching, @unchecked Sendable {
    var added: [UNNotificationRequest] = []
    var authorizationGranted = true
    var authorizationError: Error?

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        if let authorizationError { throw authorizationError }
        return authorizationGranted
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }
}
