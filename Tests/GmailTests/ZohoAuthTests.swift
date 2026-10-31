import XCTest
@testable import Gmail

final class ZohoAuthTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(ZohoAuthorizer.codeChallenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCodeVerifierIsLongEnoughAndUnreserved() {
        let verifier = ZohoAuthorizer.makeCodeVerifier()
        XCTAssertTrue((43...128).contains(verifier.count))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertNotEqual(verifier, ZohoAuthorizer.makeCodeVerifier())
    }

    func testAuthorizationURLCarriesScopesPKCEAndLoopbackRedirect() throws {
        let url = ZohoAuthorizer.authorizationURL(dataCenter: .com, clientID: "1000.ABC", codeChallenge: "chal", state: "st")
        XCTAssertEqual(url.host, "accounts.zoho.com")
        XCTAssertEqual(url.path, "/oauth/v2/auth")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "1000.ABC")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:53682/")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertEqual(items["code_challenge"], "chal")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "st")
        XCTAssertEqual(
            items["scope"],
            "ZohoMail.accounts.READ,ZohoMail.folders.READ,ZohoMail.messages.READ,ZohoMail.messages.UPDATE"
        )
        XCTAssertNil(items["client_secret"], "the secret never goes in the consent URL")
    }

    func testEUDataCenterUsesEUAccountsHost() {
        let url = ZohoAuthorizer.authorizationURL(dataCenter: .eu, clientID: "c", codeChallenge: "x", state: "s")
        XCTAssertEqual(url.host, "accounts.zoho.eu")
    }

    func testParseCallbackReadsCodeAndDataCenterHints() throws {
        let items = [
            URLQueryItem(name: "code", value: "1000.abc"),
            URLQueryItem(name: "state", value: "st"),
            URLQueryItem(name: "location", value: "eu"),
            URLQueryItem(name: "accounts-server", value: "https://accounts.zoho.eu")
        ]
        let callback = try ZohoAuthorizer.parseCallback(items, expectedState: "st")
        XCTAssertEqual(callback.code, "1000.abc")
        XCTAssertEqual(ZohoDataCenter.from(location: callback.location, accountsServer: callback.accountsServer), .eu)
    }

    func testParseCallbackRejectsWrongStateErrorsAndMissingCode() {
        XCTAssertThrowsError(try ZohoAuthorizer.parseCallback(
            [URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: "other")], expectedState: "st"))
        XCTAssertThrowsError(try ZohoAuthorizer.parseCallback(
            [URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "state", value: "st")], expectedState: "st")) { error in
            XCTAssertEqual(error as? AppError, .auth(.authorizationFailed(reason: "access_denied")))
        }
        XCTAssertThrowsError(try ZohoAuthorizer.parseCallback([URLQueryItem(name: "state", value: "st")], expectedState: "st"))
    }

    func testDataCenterFromLocation() {
        XCTAssertEqual(ZohoDataCenter.from(location: "us", accountsServer: nil), .com)
        XCTAssertEqual(ZohoDataCenter.from(location: "in", accountsServer: nil), .in)
        XCTAssertEqual(ZohoDataCenter.from(location: "au", accountsServer: nil), .comAu)
        XCTAssertEqual(ZohoDataCenter.from(location: nil, accountsServer: "https://accounts.zoho.jp"), .jp)
        XCTAssertNil(ZohoDataCenter.from(location: "mars", accountsServer: nil))
    }

    func testParseTokenResponseFromDocsShape() throws {
        let data = Data("""
        {"access_token":"1000.2dea.703a","refresh_token":"1000.18e9.1bd8","api_domain":"https://www.zohoapis.com","token_type":"Bearer","expires_in":3600}
        """.utf8)
        let now = Date(timeIntervalSince1970: 1_000)
        let session = try ZohoAuthorizer.parseTokenResponse(data, now: now, dataCenter: .com)
        XCTAssertEqual(session.accessToken, "1000.2dea.703a")
        XCTAssertEqual(session.refreshToken, "1000.18e9.1bd8")
        XCTAssertEqual(session.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(session.dataCenter, "com")
    }

    func testRefreshResponseHasNoRefreshToken() throws {
        let data = Data(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        let session = try ZohoAuthorizer.parseTokenResponse(data, now: Date(), dataCenter: .com)
        XCTAssertEqual(session.refreshToken, "")
    }

    func testTokenErrorInHTTP200BodyThrows() {
        let data = Data(#"{"error":"invalid_code"}"#.utf8)
        XCTAssertThrowsError(try ZohoAuthorizer.parseTokenResponse(data, now: Date(), dataCenter: .com)) { error in
            XCTAssertEqual(error as? AppError, .auth(.authorizationFailed(reason: "invalid_code")))
        }
    }

    func testOnlyExplicitRejectionWipesTheRefreshToken() {
        XCTAssertEqual(ZohoAuthorizer.mapRefreshError(AppError.auth(.authorizationFailed(reason: "invalid_code"))),
                       .auth(.refreshTokenInvalid))
        // Zoho's "too many requests" answer must not log the account out.
        let throttled = ZohoAuthorizer.mapRefreshError(AppError.auth(.authorizationFailed(reason: "Access Denied")))
        XCTAssertEqual(throttled.priority, .network)
        XCTAssertEqual(ZohoAuthorizer.mapRefreshError(AppError.api(.malformedResponse)).priority, .network)
    }

    func testFormBodyPercentEncodesAndSorts() {
        let body = String(decoding: ZohoAuthorizer.formBody(["b": "x y+z", "a": "1&2"]), as: UTF8.self)
        XCTAssertEqual(body, "a=1%262&b=x%20y%2Bz")
    }

    func testLoopbackRequestLineParsing() {
        let request = Data("GET /?code=1000.abc&state=st&location=us HTTP/1.1\r\nHost: 127.0.0.1:53682\r\n\r\n".utf8)
        let items = LoopbackServer.queryItems(fromRequest: request) ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "1000.abc")
        XCTAssertEqual(items.first { $0.name == "location" }?.value, "us")
        XCTAssertNil(LoopbackServer.queryItems(fromRequest: Data("POST / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertEqual(LoopbackServer.queryItems(fromRequest: Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8))?.count, 0)
    }

    func testLoopbackServerDeliversTheRedirect() async throws {
        let server = try LoopbackServer(port: 53699)
        try await server.start()
        let waiting = Task { try await server.waitForCallback() }
        let url = URL(string: "http://127.0.0.1:53699/?code=abc&state=xyz")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let items = try await waiting.value
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "abc")
    }

    func testLoopbackServerCancelFailsTheWait() async throws {
        let server = try LoopbackServer(port: 53698)
        try await server.start()
        let waiting = Task { try await server.waitForCallback() }
        try await Task.sleep(nanoseconds: 100_000_000)
        server.cancel()
        do {
            _ = try await waiting.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? AppError, .auth(.authorizationFailed(reason: "cancelled")))
        }
    }

    func testSessionDecodesWithoutDataCenterForGmailTokens() throws {
        let json = Data(#"{"accessToken":"a","refreshToken":"r","expiresAt":0,"email":"x@y.com"}"#.utf8)
        let session = try JSONDecoder().decode(AuthSession.self, from: json)
        XCTAssertNil(session.dataCenter)
    }
}
