import Foundation

/// How the OAuth consent page is shown.
enum SignInMode: Equatable, Sendable {
    /// The usual in-app ASWebAuthenticationSession sheet.
    case inApp
    /// Scriptable path for `gmailmenubar://add-account`: no browser is opened;
    /// the authorization URL is written to a file for another tool to visit,
    /// and Google redirects back to a loopback listener on 127.0.0.1.
    case externalBrowser(loginHint: String?)
}

protocol AuthorizationPerforming: Sendable {
    func performInitialAuthorization(mode: SignInMode) async throws -> AuthSession
    func performTokenRefresh(refreshToken: String) async throws -> AuthSession
    func performRevoke(refreshToken: String) async throws
}

extension AuthorizationPerforming {
    func performInitialAuthorization() async throws -> AuthSession {
        try await performInitialAuthorization(mode: .inApp)
    }
}
