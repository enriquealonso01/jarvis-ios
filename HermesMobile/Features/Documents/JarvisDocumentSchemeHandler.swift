import WebKit

/// Serves `jarvis-doc://files/<path>` (`JarvisDocuments.url`) to a document's web view: the page
/// and every file it loads by a relative URL or `fetch`, read from `JarvisFiles.folder` on the host
/// with the app's sign-in. `HermesWorkspaceFileClient` refuses a path that climbs out of the
/// folder, so a document reads only JARVIS's own files. Every answer is `no-store`, so a live
/// dashboard's next `fetch` reads what JARVIS last wrote. A file that can't be read answers an
/// HTTP status, never a hang: 404 when it is gone, 413 past the 25 MB preview cap, 502 when the
/// host can't be reached; the viewer explains a page's own failure (`JarvisDocumentWebView`).
@MainActor final class JarvisDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let files: HermesWorkspaceFileClient
    /// The reads in flight by scheme task. WebKit may stop a task at any time, and a stopped task
    /// must never be answered.
    private var reads: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(files: HermesWorkspaceFileClient) {
        self.files = files
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let url = urlSchemeTask.request.url
        reads[key] = Task { [weak self] in
            guard let self else { return }
            let (status, type, body) = await read(url)
            guard !Task.isCancelled, reads.removeValue(forKey: key) != nil, let url else { return }
            let headers = ["Content-Type": type, "Content-Length": String(body.count), "Cache-Control": "no-store",
                           "Access-Control-Allow-Origin": "*"]
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(body)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        reads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    /// Stops every read, for a web view that is going away.
    func cancelAll() {
        reads.values.forEach { $0.cancel() }
        reads.removeAll()
    }

    private func read(_ url: URL?) async -> (status: Int, type: String, body: Data) {
        let failure = "text/plain; charset=utf-8"
        guard let url, let path = JarvisDocuments.path(for: url) else { return (404, failure, Data()) }
        do {
            return (200, JarvisDocuments.contentType(for: path), try await files.rawFilePreviewData(path: path))
        } catch BotArtifactFailure.tooLarge {
            return (413, failure, Data())
        } catch is BotArtifactFailure {
            return (404, failure, Data())
        } catch {
            return (502, failure, Data())
        }
    }
}
