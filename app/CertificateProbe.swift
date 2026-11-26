// Deploy Center — When the site's TLS certificate ends (FEA-085), read from the handshake of one
// request. Only the leaf's "not after"; the trust decision stays the system's.

import Foundation
import Security

final class CertificateProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _notAfter: Date?
    /// The earliest end over every host of a redirect chain (apex → www): the certificate the
    /// visitor types is checked too, not only the last one (IDEEN-11 199).
    private var notAfter: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _notAfter }
        set {
            lock.lock(); defer { lock.unlock() }
            if let n = newValue { _notAfter = _notAfter.map { min($0, n) } ?? n }
        }
    }
    /// A redirect to localhost or a private address is not followed (IDEEN-11 220).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(PublicRedirect.allows(request.url) ? request : nil)
    }

    /// The leaf certificate's end, nil when nothing answered or it could not be read.
    static func expiry(_ url: URL) async -> Date? {
        let probe = CertificateProbe()
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil
        let session = URLSession(configuration: c, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "HEAD"
        req.setValue("DeployCenter (post-deploy check)", forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: req)
        return probe.notAfter
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            notAfter = Self.notAfter(leaf)
        }
        // The system decides as for any other request.
        completionHandler(.performDefaultHandling, nil)
    }

    private static func notAfter(_ cert: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let n = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        // Seconds since 2001-01-01, as CFAbsoluteTime.
        return Date(timeIntervalSinceReferenceDate: n.doubleValue)
    }
}

/// One rule for every redirect the app follows on its own: only https, only a public host (also by DNS).
/// A page that answers "moved" to `http://`, localhost or a cloud metadata address is not followed, so the
/// status that decides a warning or an automatic rollback never comes from there.
enum PublicRedirect {
    nonisolated static func allows(_ url: URL?) -> Bool {
        guard let url, LogoCache.allowed(url) else { return false }
        return LogoCache.resolvesPublic(url.host ?? "")
    }
}

/// Per-request delegate for `URLSession.bytes(for:delegate:)`: refuses a redirect `PublicRedirect` refuses.
final class PublicRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        PublicRedirect.allows(request.url) ? request : nil
    }
}
