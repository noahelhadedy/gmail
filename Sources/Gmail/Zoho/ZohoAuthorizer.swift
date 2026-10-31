import Foundation
import AppKit
import CryptoKit

/// Zoho OAuth 2.0 (authorization code + PKCE) over a fixed loopback redirect.
/// Tokens are exchanged with plain URLSession, so AuthService can reuse the
/// same Keychain/refresh logic as Gmail through `AuthorizationPerforming`.
final class ZohoAuthorizer: AuthorizationPerforming, @unchecked Sendable {
    /// Register exactly this redirect URI in the Zoho API Console.
    static let redirectPort: UInt16 = 53682
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/"
    static let scopes = [
        "ZohoMail.accounts.READ",
        "ZohoMail.folders.READ",
        "ZohoMail.messages.READ",
        "ZohoMail.messages.UPDATE"
    ]
    static let flowTimeout: TimeInterval = 5 * 60

    private let clientID: String
    private let clientSecret: String
    private let dataCenter: ZohoDataCenter
    private let urlSession: URLSession
    private let now: @Sendable () -> Date
    private let openBrowser: @Sendable (URL) -> Void

    private let lock = NSLock()
    private var activeServer: LoopbackServer?

    init(
        clientID: String,
        clientSecret: String,
        dataCenter: ZohoDataCenter = .com,
        urlSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        openBrowser: @escaping @Sendable (URL) -> Void = { url in
            DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) }
        }
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.dataCenter = dataCenter
        self.urlSession = urlSession
        self.now = now
        self.openBrowser = openBrowser
    }

    // MARK: AuthorizationPerforming

    func performInitialAuthorization(mode: SignInMode) async throws -> AuthSession {
        let verifier = Self.makeCodeVerifier()
        let state = Self.makeCodeVerifier(length: 32)
        let url = Self.authorizationURL(
            dataCenter: dataCenter,
            clientID: clientID,
            codeChallenge: Self.codeChallenge(for: verifier),
            state: state
        )

        cancelAuthorization()
        let server: LoopbackServer
        do {
            server = try LoopbackServer(port: Self.redirectPort)
            try await server.start()
        } catch {
            throw AppError.auth(.authorizationFailed(
                reason: "port \(Self.redirectPort) unavailable: \(error.localizedDescription)"
            ))
        }
        setActive(server)
        defer { clearActive(server) }

        let pendingFile = AutomationFiles.pendingAuthURL
        switch mode {
        case .inApp:
            openBrowser(url)
        case .externalBrowser:
            do {
                try AutomationFiles.writePrivate(Data(url.absoluteString.utf8), to: pendingFile)
            } catch {
                server.cancel(reason: "could not write pending-auth-url.txt")
                throw AppError.auth(.authorizationFailed(reason: "could not write pending-auth-url.txt"))
            }
        }
        defer { if case .externalBrowser = mode { AutomationFiles.remove(pendingFile) } }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.flowTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            server.cancel(reason: "timed out after \(Int(Self.flowTimeout / 60)) minutes")
        }
        defer { timeout.cancel() }

        let items = try await server.waitForCallback()
        let callback = try Self.parseCallback(items, expectedState: state)
        let tokenDC = ZohoDataCenter.from(location: callback.location, accountsServer: callback.accountsServer)
            ?? dataCenter
        return try await exchange(code: callback.code, verifier: verifier, dataCenter: tokenDC)
    }

    func performTokenRefresh(refreshToken: String) async throws -> AuthSession {
        let data = try await postForm(
            host: dataCenter.accountsHost,
            path: "/oauth/v2/token",
            fields: [
                "grant_type": "refresh_token",
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refreshToken
            ]
        )
        do {
            return try Self.parseTokenResponse(data, now: now(), dataCenter: dataCenter)
        } catch {
            throw Self.mapRefreshError(error)
        }
    }

    /// Only an explicit rejection of the refresh token may wipe it. Zoho also
    /// answers "Access Denied" when refreshes come too fast, and a garbled
    /// reply says nothing about the token, so both are retried next tick.
    static func mapRefreshError(_ error: Error) -> AppError {
        if case AppError.auth(.authorizationFailed(let reason)) = error {
            let rejected = ["invalid_code", "invalid_client", "invalid_token", "invalid_grant"]
            return rejected.contains(reason.lowercased())
                ? .auth(.refreshTokenInvalid)
                : .network(.unknown(reason: "Zoho token refresh: \(reason)"))
        }
        if let appError = error as? AppError, appError.priority == .network { return appError }
        return .network(.unknown(reason: "Zoho token refresh failed"))
    }

    func performRevoke(refreshToken: String) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = dataCenter.accountsHost
        components.path = "/oauth/v2/token/revoke"
        components.queryItems = [URLQueryItem(name: "token", value: refreshToken)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.auth(.revocationFailed)
        }
    }

    /// Stops a sign-in that is waiting for the browser (a newer request wins).
    func cancelAuthorization() {
        lock.lock()
        let server = activeServer
        lock.unlock()
        server?.cancel()
    }

    // MARK: Token exchange

    private func exchange(code: String, verifier: String, dataCenter: ZohoDataCenter) async throws -> AuthSession {
        let data = try await postForm(
            host: dataCenter.accountsHost,
            path: "/oauth/v2/token",
            fields: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "client_secret": clientSecret,
                "redirect_uri": Self.redirectURI,
                "code": code,
                "code_verifier": verifier
            ]
        )
        let session = try Self.parseTokenResponse(data, now: now(), dataCenter: dataCenter)
        guard !session.refreshToken.isEmpty else {
            throw AppError.auth(.authorizationFailed(reason: "Zoho returned no refresh token"))
        }
        return session
    }

    private func postForm(host: String, path: String, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppError.network(.unknown(reason: error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            throw AppError.network(.unknown(reason: "Zoho accounts server HTTP \(http.statusCode)"))
        }
        return data
    }

    private func setActive(_ server: LoopbackServer) {
        lock.lock()
        activeServer = server
        lock.unlock()
    }

    private func clearActive(_ server: LoopbackServer) {
        lock.lock()
        if activeServer === server { activeServer = nil }
        lock.unlock()
    }

    // MARK: Pure helpers (unit tested)

    static func authorizationURL(
        dataCenter: ZohoDataCenter,
        clientID: String,
        codeChallenge: String,
        state: String
    ) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = dataCenter.accountsHost
        components.path = "/oauth/v2/auth"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: ",")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    struct Callback: Equatable {
        let code: String
        let location: String?
        let accountsServer: String?
    }

    static func parseCallback(_ items: [URLQueryItem], expectedState: String) throws -> Callback {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw AppError.auth(.authorizationFailed(reason: error))
        }
        guard value("state") == expectedState else {
            throw AppError.auth(.authorizationFailed(reason: "state mismatch"))
        }
        guard let code = value("code"), !code.isEmpty else {
            throw AppError.auth(.authorizationFailed(reason: "no authorization code"))
        }
        return Callback(code: code, location: value("location"), accountsServer: value("accounts-server"))
    }

    /// Zoho answers token errors with HTTP 200 and `{"error": "invalid_code"}`.
    static func parseTokenResponse(_ data: Data, now: Date, dataCenter: ZohoDataCenter) throws -> AuthSession {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.api(.malformedResponse)
        }
        if let error = json["error"] as? String {
            throw AppError.auth(.authorizationFailed(reason: error))
        }
        guard let accessToken = json["access_token"] as? String else {
            throw AppError.auth(.authorizationFailed(reason: "missing access token"))
        }
        let lifetime = (json["expires_in"] as? Double) ?? (json["expires_in_sec"] as? Double) ?? 3600
        return AuthSession(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? "",
            idToken: nil,
            expiresAt: now.addingTimeInterval(lifetime),
            email: nil,
            dataCenter: dataCenter.rawValue
        )
    }

    static func makeCodeVerifier(length: Int = 64) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = fields.keys.sorted().map { key -> String in
            let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
