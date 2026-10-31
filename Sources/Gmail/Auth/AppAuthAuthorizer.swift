import Foundation
import AppKit
@preconcurrency import AppAuth

/// Real AppAuth-iOS-backed implementation of AuthorizationPerforming.
///
/// All ASWebAuthenticationSession + AppAuth interactions are routed onto the
/// main actor because OIDExternalUserAgentMac touches AppKit. Network-only
/// work (discovery, refresh, revoke) does not require the main actor but is
/// kept here for cohesion.
final class AppAuthAuthorizer: AuthorizationPerforming, @unchecked Sendable {
    static let googleIssuer = URL(string: "https://accounts.google.com")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    // gmail.modify (a superset of gmail.readonly) is needed for "Mark as read".
    static let defaultScopes = ["https://www.googleapis.com/auth/gmail.modify"]

    private let clientID: String
    private let clientSecret: String?
    private let redirectURL: URL
    private let scopes: [String]
    private let urlSession: URLSession

    private let configurationCache = ConfigurationCache()

    /// Holds the in-flight ASWebAuthenticationSession-backed flow so its
    /// callback target stays alive. OIDExternalUserAgentMac holds the
    /// session as `__weak`; without retaining here the OAuth redirect
    /// becomes a no-op even though Safari completes the flow.
    nonisolated(unsafe) private var currentAuthorizationFlow: OIDExternalUserAgentSession?

    /// Loopback listener for the scriptable `.externalBrowser` flow. Retained
    /// for the flow's lifetime; its HTTP server delivers Google's redirect.
    nonisolated(unsafe) private var loopbackHandler: OIDRedirectHTTPHandler?
    nonisolated(unsafe) private var loopbackTimeout: Task<Void, Never>?
    nonisolated(unsafe) private var loopbackTimedOut = false

    /// How long an external-browser sign-in may wait for Google's redirect.
    static let externalFlowTimeout: TimeInterval = 5 * 60

    init(
        clientID: String,
        clientSecret: String? = nil,
        redirectURL: URL,
        scopes: [String] = AppAuthAuthorizer.defaultScopes,
        urlSession: URLSession = .shared
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURL = redirectURL
        self.scopes = scopes
        self.urlSession = urlSession
    }

    func performInitialAuthorization(mode: SignInMode) async throws -> AuthSession {
        let configuration = try await discoverConfiguration()
        if case .externalBrowser(let loginHint) = mode {
            return try await presentLoopbackAuthorization(configuration: configuration, loginHint: loginHint)
        }
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientID,
            clientSecret: clientSecret,
            scopes: scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: [
                "access_type": "offline",
                "prompt": "consent"
            ]
        )
        return try await presentAuthorization(request: request)
    }

    func performTokenRefresh(refreshToken: String) async throws -> AuthSession {
        let configuration = try await discoverConfiguration()
        let request = OIDTokenRequest(
            configuration: configuration,
            grantType: OIDGrantTypeRefreshToken,
            authorizationCode: nil,
            redirectURL: redirectURL,
            clientID: clientID,
            clientSecret: clientSecret,
            scope: nil,
            refreshToken: refreshToken,
            codeVerifier: nil,
            additionalParameters: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.perform(request) { response, error in
                if let error {
                    continuation.resume(throwing: Self.mapRefreshError(error))
                    return
                }
                guard let response, let accessToken = response.accessToken else {
                    continuation.resume(throwing: AppError.auth(.refreshTokenInvalid))
                    return
                }
                let session = AuthSession(
                    accessToken: accessToken,
                    refreshToken: response.refreshToken ?? "",
                    idToken: response.idToken,
                    expiresAt: response.accessTokenExpirationDate ?? Date().addingTimeInterval(3600),
                    email: nil
                )
                continuation.resume(returning: session)
            }
        }
    }

    func performRevoke(refreshToken: String) async throws {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.auth(.revocationFailed)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError.auth(.revocationFailed)
        }
    }

    @MainActor
    private func presentAuthorization(request: OIDAuthorizationRequest) async throws -> AuthSession {
        try await withCheckedThrowingContinuation { continuation in
            let presentingWindow = NSApp.windows.first ?? NSWindow()
            let userAgent = OIDExternalUserAgentMac(presenting: presentingWindow)
            self.currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: userAgent
            ) { [weak self] authState, error in
                self?.currentAuthorizationFlow = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let authState else {
                    continuation.resume(
                        throwing: AppError.auth(.authorizationFailed(reason: "no auth state"))
                    )
                    return
                }
                do {
                    let session = try Self.session(from: authState)
                    continuation.resume(returning: session)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Cancels a pending external-browser sign-in, if any. Its caller gets
    /// AppAuth's "program canceled" error.
    @MainActor
    func cancelExternalAuthorization() {
        loopbackHandler?.cancelHTTPListener()
    }

    /// Desktop OAuth clients accept http://127.0.0.1:<any port>/ as a redirect.
    /// The authorization URL goes to a file instead of a browser so another
    /// tool can open it in a browser it controls.
    @MainActor
    private func presentLoopbackAuthorization(
        configuration: OIDServiceConfiguration,
        loginHint: String?
    ) async throws -> AuthSession {
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirect: URL? = handler.startHTTPListener(&listenerError)
        guard let redirect, listenerError == nil else {
            throw listenerError ?? AppError.auth(.authorizationFailed(reason: "loopback listener failed"))
        }
        var parameters = [
            "access_type": "offline",
            "prompt": "consent"
        ]
        if let loginHint { parameters["login_hint"] = loginHint }
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientID,
            clientSecret: clientSecret,
            scopes: scopes,
            redirectURL: redirect,
            responseType: OIDResponseTypeCode,
            additionalParameters: parameters
        )
        let pendingFile = AutomationFiles.pendingAuthURL
        loopbackHandler = handler
        loopbackTimedOut = false

        return try await withCheckedThrowingContinuation { continuation in
            handler.currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: AuthURLFileUserAgent(fileURL: pendingFile)
            ) { [weak self] authState, error in
                let timedOut = self?.loopbackTimedOut ?? false
                self?.loopbackTimeout?.cancel()
                self?.loopbackTimeout = nil
                self?.loopbackHandler = nil
                handler.stopHTTPListenerIfRunning()
                AutomationFiles.remove(pendingFile)
                if timedOut {
                    continuation.resume(throwing: AppError.auth(.authorizationFailed(
                        reason: "timed out after \(Int(Self.externalFlowTimeout / 60)) minutes"
                    )))
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let authState else {
                    continuation.resume(
                        throwing: AppError.auth(.authorizationFailed(reason: "no auth state"))
                    )
                    return
                }
                do {
                    continuation.resume(returning: try Self.session(from: authState))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            loopbackTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.externalFlowTimeout * 1_000_000_000))
                guard !Task.isCancelled, let self, self.loopbackHandler === handler else { return }
                self.loopbackTimedOut = true
                handler.cancelHTTPListener()
            }
        }
    }

    private func discoverConfiguration() async throws -> OIDServiceConfiguration {
        if let cached = await configurationCache.get() {
            return cached.value
        }
        let configuration: OIDServiceConfiguration = try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.discoverConfiguration(
                forIssuer: Self.googleIssuer
            ) { configuration, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let configuration else {
                    continuation.resume(
                        throwing: AppError.auth(.authorizationFailed(reason: "discovery failed"))
                    )
                    return
                }
                continuation.resume(returning: configuration)
            }
        }
        await configurationCache.set(configuration)
        return configuration
    }

    private struct UncheckedConfig: @unchecked Sendable {
        let value: OIDServiceConfiguration
    }

    private actor ConfigurationCache {
        private var stored: UncheckedConfig?
        func get() -> UncheckedConfig? { stored }
        func set(_ value: OIDServiceConfiguration) { stored = UncheckedConfig(value: value) }
    }

    /// Connectivity failures must not look like a revoked token, otherwise a
    /// laptop waking up offline would wipe every account's refresh token.
    private static func mapRefreshError(_ error: Error) -> Error {
        let nsError = error as NSError
        let isNetwork = nsError.domain == NSURLErrorDomain
            || (nsError.domain == OIDGeneralErrorDomain && nsError.code == OIDErrorCode.networkError.rawValue)
        return isNetwork ? AppError.network(.unknown(reason: nsError.localizedDescription)) : error
    }

    private static func session(from authState: OIDAuthState) throws -> AuthSession {
        guard let accessToken = authState.lastTokenResponse?.accessToken,
              let refreshToken = authState.lastTokenResponse?.refreshToken,
              let expiresAt = authState.lastTokenResponse?.accessTokenExpirationDate else {
            throw AppError.auth(.authorizationFailed(reason: "missing tokens"))
        }
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: authState.lastTokenResponse?.idToken,
            expiresAt: expiresAt,
            email: nil
        )
    }
}

/// "Opens" the consent page by writing its URL to a file (mode 0600) for
/// another tool to visit. The URL holds only the client ID, state and PKCE
/// challenge, never a secret.
private final class AuthURLFileUserAgent: NSObject, OIDExternalUserAgent {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func present(_ request: OIDExternalUserAgentRequest, session: OIDExternalUserAgentSession) -> Bool {
        guard let data = request.externalUserAgentRequestURL().absoluteString.data(using: .utf8) else {
            return false
        }
        do {
            try AutomationFiles.writePrivate(data, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        completion()
    }
}

private extension OIDRedirectHTTPHandler {
    /// `stopHTTPListener` is private in AppAuth; cancelling with no current
    /// flow just stops the server.
    func stopHTTPListenerIfRunning() {
        currentAuthorizationFlow = nil
        cancelHTTPListener()
    }
}
