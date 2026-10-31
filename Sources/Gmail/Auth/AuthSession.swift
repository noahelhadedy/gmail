import Foundation

struct AuthSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresAt: Date
    let email: String?
    /// Zoho only: raw `ZohoDataCenter` the tokens belong to.
    var dataCenter: String? = nil

    func withEmail(_ email: String) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            email: email,
            dataCenter: dataCenter
        )
    }

    func isAccessTokenFresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt > now.addingTimeInterval(leeway)
    }
}
