import XCTest
@testable import Gmail

final class EmailMessageTests: XCTestCase {
    func testDisplayFromKeepsNameOnly() {
        XCTAssertEqual(make(from: "\"Polar\" <hi@polar.sh>").displayFrom, "Polar")
        XCTAssertEqual(make(from: "Alice Smith <alice@x.com>").displayFrom, "Alice Smith")
    }

    func testDisplayFromFallsBackToAddress() {
        XCTAssertEqual(make(from: "<bot@x.com>").displayFrom, "bot@x.com")
        XCTAssertEqual(make(from: "bare@x.com").displayFrom, "bare@x.com")
        XCTAssertEqual(make(from: "").displayFrom, "(unknown sender)")
    }

    func testSnippetDecodesHTMLEntities() {
        XCTAssertEqual(make(snippet: "It&#39;s &quot;done&quot; &amp; shipped").displaySnippet, "It's \"done\" & shipped")
        XCTAssertEqual(make(snippet: "&amp;lt;b&amp;gt;").displaySnippet, "&lt;b&gt;", "decode one level only")
        XCTAssertEqual(make(snippet: nil).displaySnippet, "")
    }

    private func make(from: String = "x@y.com", snippet: String? = nil) -> EmailMessage {
        EmailMessage(id: "m", threadId: "t", from: from, subject: "s", internalDate: Date(), snippet: snippet)
    }
}
