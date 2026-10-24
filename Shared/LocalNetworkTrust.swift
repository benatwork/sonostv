import Foundation

/// Sonos players serve their local API over TLS with a self-signed certificate.
/// This delegate trusts it, but only for hosts with a private (RFC 1918) IPv4 address.
nonisolated final class LocalNetworkTrust: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              Self.isPrivateAddress(space.host)
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func isPrivateAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (172, 16...31):
            return true
        default:
            return false
        }
    }
}
