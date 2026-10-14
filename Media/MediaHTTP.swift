import Foundation
import WebKit

/// One transfer owns its cookie snapshot. Redirects use URLSession's destination-scoped
/// cookie handling, rather than forwarding a page's Cookie/Authorization header blindly.
final class MediaHTTP: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let page: URL
    private let cookieStorage: HTTPCookieStorage
    private let limit: Int64
    private let progress: @Sendable (Int64, Int64) -> Void

    init(page: URL, cookies: [HTTPCookie], limit: Int64 = 256 * 1024 * 1024,
         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        self.page = page
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

    func download(_ url: URL, to destination: URL, range: HLSPlaylist.ByteRange? = nil) async throws -> HTTPURLResponse {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else {
            throw MediaFailure.invalid("Unsupported media URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 DevTools-iOS/2.0", forHTTPHeaderField: "User-Agent")
        request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        if let range {
            request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
        }
        let (temporary, response) = try await session.download(for: request)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              range == nil || http.statusCode == 206 else {
            throw MediaFailure.invalid("The media server rejected the request or ignored its byte range.")
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, Int64(size) <= limit, range == nil || Int64(size) == range?.length else {
            throw MediaFailure.invalid("Empty, oversized or incomplete media response.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return http
    }

    func data(_ url: URL, maximum: Int = 2 * 1024 * 1024) async throws -> (Data, URL) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        let response = try await download(url, to: temporary)
        guard (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximum else {
            throw MediaFailure.invalid("Media metadata exceeds its size limit.")
        }
        return (try Data(contentsOf: temporary), response.url ?? url)
    }

    func playlist(_ url: URL) async throws -> HLSPlaylist {
        let (data, resolved) = try await data(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MediaFailure.invalid("Invalid playlist text.")
        }
        return try HLSPlaylist.parse(text, base: resolved)
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
