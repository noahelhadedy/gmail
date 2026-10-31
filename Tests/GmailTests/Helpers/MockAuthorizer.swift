import Foundation
@testable import Gmail

final class MockAuthorizer: AuthorizationPerforming, @unchecked Sendable {
    var initialResult: Result<AuthSession, Error> = .failure(NSError(domain: "mock", code: 0))
    var refreshResult: Result<AuthSession, Error> = .failure(NSError(domain: "mock", code: 0))
    var revokeError: Error?
    var refreshCallCount = 0
    var revokeCallCount = 0
    var lastSignInMode: SignInMode?

    func performInitialAuthorization(mode: SignInMode) async throws -> AuthSession {
        lastSignInMode = mode
        return try initialResult.get()
    }

    func performTokenRefresh(refreshToken: String) async throws -> AuthSession {
        refreshCallCount += 1
        return try refreshResult.get()
    }

    func performRevoke(refreshToken: String) async throws {
        revokeCallCount += 1
        if let revokeError { throw revokeError }
    }
}
