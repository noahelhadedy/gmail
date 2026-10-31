import XCTest
@testable import Gmail

final class GmailWebURLTests: XCTestCase {
    func testThreadURLTargetsAccountWithAuthuser() {
        XCTAssertEqual(
            GmailWebURL.thread(email: "hello@djectstudio.com", threadId: "18f2a").absoluteString,
            "https://mail.google.com/mail/?authuser=hello@djectstudio.com#inbox/18f2a"
        )
    }

    func testInboxURLTargetsAccountWithAuthuser() {
        XCTAssertEqual(
            GmailWebURL.inbox(email: "noohelhadedy@gmail.com").absoluteString,
            "https://mail.google.com/mail/?authuser=noohelhadedy@gmail.com#inbox"
        )
    }

    func testPlusAddressIsEscapedSoGoogleDoesNotReadASpace() {
        let url = GmailWebURL.inbox(email: "noah+work@gmail.com")
        XCTAssertEqual(url.absoluteString, "https://mail.google.com/mail/?authuser=noah%2Bwork@gmail.com#inbox")
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "authuser" }?.value
        XCTAssertEqual(value, "noah+work@gmail.com")
    }

    func testEmptyEmailOmitsAuthuser() {
        XCTAssertEqual(GmailWebURL.inbox(email: "").absoluteString, "https://mail.google.com/mail/#inbox")
    }

    func testNotificationURLMatchesThreadURL() {
        XCTAssertEqual(
            NotificationManager.gmailURL(email: "a@example.com", threadId: "t1"),
            GmailWebURL.thread(email: "a@example.com", threadId: "t1")
        )
    }
}
