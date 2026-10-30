import SwiftUI
import WebKit

/// One of JARVIS's documents, full screen: its page in a web view (`JarvisDocumentWebView`)
/// titled by its own `<title>`. While it is on screen it asks the host every
/// `JarvisDocuments.watchInterval` whether JARVIS changed the file, and loads the new version in
/// place, keeping the reader's position; a live dashboard updates itself in between
/// (`Jarvis.live`). A link to another of JARVIS's files opens it on its own screen, so Back returns
/// here. Pull down to reload.
struct JarvisDocumentView: View {
    let place: JarvisDocuments.Place
    let route: JarvisDocuments.Route

    @Environment(\.scenePhase) private var scenePhase
    @State private var title: String?
    @State private var phase = JarvisDocumentPhase.loading
    @State private var reloads = 0
    /// The last listing reading of the file; nil before the first one. Kept across background
    /// trips, so a change JARVIS made meanwhile still reloads the page.
    @State private var seen: JarvisDocuments.Version??
    @State private var linked: JarvisDocuments.Route?

    var body: some View {
        Group {
            if let url = JarvisDocuments.url(for: route.path) {
                JarvisDocumentWebView(url: url, place: place, reloads: reloads, title: $title, phase: $phase) { path in
                    linked = JarvisDocuments.Route(linked: path)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                Color.clear.onAppear { phase = .missing }
            }
        }
        .overlay { overlay }
        .navigationTitle(title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reloads += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("jarvisDocument.reload")
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await watch()
        }
        .navigationDestination(item: $linked) { JarvisDocumentView(place: place, route: $0) }
    }

    @ViewBuilder private var overlay: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            EmptyView()
        case .missing, .unavailable:
            ContentUnavailableView {
                if phase == .missing {
                    Label("Document Not Found", systemImage: "doc.questionmark")
                } else {
                    Label("Document Unavailable", systemImage: "exclamationmark.triangle")
                }
            } description: {
                if phase == .missing {
                    Text("JARVIS may have moved or deleted it.")
                } else {
                    Text("JARVIS couldn't be reached. Check your connection and try again.")
                }
            } actions: {
                Button("Try Again") { reloads += 1 }
            }
            .background(Color(.systemBackground))
            .accessibilityIdentifier("jarvisDocument.failed")
        }
    }

    /// Reloads the page whenever the file's listing row changes. A reading that fails says
    /// nothing about the file, so it is skipped.
    private func watch() async {
        let http = place.http
        while !Task.isCancelled {
            do {
                let now = try await JarvisDocuments.version(of: route.path, on: http)
                if let seen, seen != now { reloads += 1 }
                seen = .some(now)
            } catch {}
            try? await Task.sleep(for: JarvisDocuments.watchInterval)
        }
    }
}

enum JarvisDocumentPhase: Equatable {
    /// Before the page first finishes loading.
    case loading
    case ready
    /// The host has no such file (404).
    case missing
    /// The host couldn't be reached or refused the page.
    case unavailable
}

/// The web view under a document: `jarvis-doc` URLs served by `JarvisDocumentSchemeHandler`, the
/// app's kit (`JarvisDocumentKit`) in every page, and links kept in their place: the same page
/// (an anchor or a reload) stays, another of JARVIS's files goes to `openLink`, and anything else
/// (https, mail, phone) opens in its own app. An embedded frame loads in place. `reloads` going up
/// loads the page again at the same scroll position.
struct JarvisDocumentWebView: UIViewRepresentable {
    let url: URL
    let place: JarvisDocuments.Place
    let reloads: Int
    @Binding var title: String?
    @Binding var phase: JarvisDocumentPhase
    let openLink: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self, handler: JarvisDocumentSchemeHandler(files: place.files()))
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.handler, forURLScheme: JarvisDocuments.scheme)
        for script in JarvisDocumentKit.userScripts { configuration.userContentController.addUserScript(script) }
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = [.link, .phoneNumber]
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pulled), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.webView = webView
        context.coordinator.reloads = reloads
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.reloads != reloads {
            context.coordinator.reloads = reloads
            context.coordinator.reload(webView)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.handler.cancelAll()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: JarvisDocumentWebView
        let handler: JarvisDocumentSchemeHandler
        weak var webView: WKWebView?
        var reloads = 0
        /// How far down the page the reader was when a reload started, in CSS pixels, restored
        /// once it finishes.
        private var restoreOffset: CGFloat?

        init(_ parent: JarvisDocumentWebView, handler: JarvisDocumentSchemeHandler) {
            self.parent = parent
            self.handler = handler
        }

        @objc func pulled() {
            guard let webView else { return }
            reload(webView)
        }

        func reload(_ webView: WKWebView) {
            let scroll = webView.scrollView
            restoreOffset = max(0, (scroll.contentOffset.y + scroll.adjustedContentInset.top) / max(scroll.zoomScale, 0.01))
            if webView.url == nil { webView.load(URLRequest(url: parent.url)) } else { webView.reload() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            if let path = JarvisDocuments.path(for: url) {
                // The page itself, an anchor in it or a reload; frames load in place.
                if !isMainFrame || path == JarvisDocuments.path(for: parent.url) { return decisionHandler(.allow) }
                parent.openLink(path)
                return decisionHandler(.cancel)
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["about", "data", "blob"].contains(scheme) || (!isMainFrame && navigationAction.targetFrame != nil) {
                return decisionHandler(.allow)
            }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
               response.statusCode >= 400 {
                parent.phase = response.statusCode == 404 ? .missing : .unavailable
                webView.scrollView.refreshControl?.endRefreshing()
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.phase = .ready
            if let title = webView.title, !title.trimmingCharacters(in: .whitespaces).isEmpty { parent.title = title }
            webView.scrollView.refreshControl?.endRefreshing()
            if let offset = restoreOffset {
                restoreOffset = nil
                webView.evaluateJavaScript("window.scrollTo(0, \(Int(offset)))")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            failed(webView, error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failed(webView, error)
        }

        /// A page the web view's process lost (memory pressure in the background) comes back blank.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reload(webView)
        }

        /// A cancelled load, or one this delegate stopped for a failed response (WebKit's "frame
        /// load interrupted", 102), is not a failure.
        private func failed(_ webView: WKWebView, _ error: any Error) {
            webView.scrollView.refreshControl?.endRefreshing()
            let error = error as NSError
            let isCancel = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
                || (error.domain == "WebKitErrorDomain" && error.code == 102)
            if !isCancel, parent.phase != .missing { parent.phase = .unavailable }
        }
    }
}
