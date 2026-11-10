import Foundation

/// Bounded text fetching for explicit userscript URL imports.
/// Redirects scope cookies to their destination and do not forward authorization headers.
final class MediaHTTP: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let page: URL
    private let userAgent: String
    private let cookieStorage: HTTPCookieStorage
    private let limit: Int64
    private let progress: @Sendable (Int64, Int64) -> Void

    init(page: URL, cookies: [HTTPCookie], userAgent: String? = nil, limit: Int64 = 256 * 1024,
         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        self.page = page
        self.userAgent = userAgent?.isEmpty == false ? userAgent! : "Mozilla/5.0 DevTools-iOS/2.0"
        self.limit = limit
        self.progress = progress
        let configuration = URLSessionConfiguration.ephemeral
        cookieStorage = configuration.httpCookieStorage ?? HTTPCookieStorage.shared
        super.init()
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
        configuration.httpCookieStorage = cookieStorage
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func close() {
        session.invalidateAndCancel()
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func download(_ url: URL, to destination: URL) async throws -> HTTPURLResponse {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else {
            throw MediaFailure.invalid("Unsupported script URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        let (temporary, response) = try await session.download(for: request)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MediaFailure.invalid("The script server rejected the request (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer {
            try? handle.close()
        }
        let prefix = try handle.read(upToCount: 1024) ?? Data()
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mime = http.mimeType?.lowercased() ?? ""
        guard mime != "text/html", mime != "application/xhtml+xml",
              !text.hasPrefix("<!doctype html"), !text.hasPrefix("<html") else {
            let redirected = http.url != url
            let pageURL = url.absoluteString.split(separator: "#").first == page.absoluteString.split(separator: "#").first
            let challenge = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" || text.contains("cf-chl-") || text.contains("challenges.cloudflare.com")
            let details = "HTTP \(http.statusCode); type \(mime.isEmpty ? "unspecified" : mime); requested host \(url.host ?? "unknown"); response host \(http.url?.host ?? "unknown"); redirected \(redirected ? "yes" : "no"); source equals page \(pageURL ? "yes" : "no"); challenge markers \(challenge ? "yes" : "no")."
            throw MediaFailure.invalid("The server returned a webpage instead of JavaScript. " + details + " Check the userscript URL and try again.")
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, Int64(size) <= limit else {
            throw MediaFailure.invalid("Empty or oversized script response.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return http
    }

    func data(_ url: URL, maximum: Int = 256 * 1024) async throws -> (Data, URL) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        let response = try await download(url, to: temporary)
        guard (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximum else {
            throw MediaFailure.invalid("Script source exceeds its size limit.")
        }
        return (try Data(contentsOf: temporary), response.url ?? url)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit {
            downloadTask.cancel()
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Async URLSession.download(for:) owns the temporary file's handoff.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil,
              !(response.url?.scheme == "https" && url.scheme == "http") else {
            completionHandler(nil)
            return
        }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        // Cookies are regenerated for the redirect destination by the session's cookie jar.
        if let cookies = cookieStorage.cookies(for: url) {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                safe.setValue(value, forHTTPHeaderField: name)
            }
        }
        completionHandler(safe)
    }
}
