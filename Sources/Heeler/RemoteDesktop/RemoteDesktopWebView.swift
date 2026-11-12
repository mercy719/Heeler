import SwiftUI
import WebKit

/// The calls the screen makes into `viewer.js`, and the one `WKWebView` they
/// reach. The view owns it; the WebView attaches to it when SwiftUI builds it.
@MainActor
@Observable
final class RemoteDesktopPage {
    @ObservationIgnored weak var webView: WKWebView?

    /// Calls one method of the page's script. Each value is JSON, so no value
    /// can end the call early.
    func call(_ method: String, _ values: Any...) {
        guard let webView else { return }
        let arguments = values.compactMap { value -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                let json = String(data: data, encoding: .utf8), json.count >= 2
            else { return nil }
            return String(json.dropFirst().dropLast())
        }.joined(separator: ",")
        webView.evaluateJavaScript(
            "window.__heelerRD && window.__heelerRD.\(method)(\(arguments));true;")
    }
}

/// The Moonlight page in a WKWebView. It loads the loopback URL this session
/// was given and refuses every other host: the page is the only thing here
/// that may see a URL, and it never leaves 127.0.0.1.
struct RemoteDesktopWebView: UIViewRepresentable {
    let url: URL
    let quality: RemoteDesktopQuality
    let ready: RemoteDesktopReady
    let touchMode: RemoteDesktopTouchMode
    /// What the app's own controls cover, so the zoom follow keeps the pointer
    /// clear of them.
    let covered: (top: CGFloat, bottom: CGFloat)
    let page: RemoteDesktopPage
    let onStats: @MainActor ([String: Any]) -> Void
    let onFirstFrame: @MainActor () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing persists: the page keeps its settings in local storage, and
        // the next session must not inherit a stale transport or size.
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "heelerRD")
        controller.addUserScript(
            WKUserScript(
                source: Self.configScript(
                    quality: quality, ready: ready, touchMode: touchMode, covered: covered),
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let viewer = Self.viewerScript() {
            controller.addUserScript(
                WKUserScript(
                    source: viewer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
            webView.isInspectable = true
        #endif
        page.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStats = onStats
        context.coordinator.onFirstFrame = onFirstFrame
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "heelerRD")
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStats: onStats, onFirstFrame: onFirstFrame)
    }

    /// The parameters the script reads before the page's own code runs.
    static func configScript(
        quality: RemoteDesktopQuality, ready: RemoteDesktopReady,
        touchMode: RemoteDesktopTouchMode, covered: (top: CGFloat, bottom: CGFloat)
    ) -> String {
        let size = quality.streamSize(for: ready)
        let config: [String: Any] = [
            "fps": quality.fps,
            "bitrate": quality.bitrateKbps,
            "width": size.width,
            "height": size.height,
            "touchMode": touchMode.pageValue,
            "background": "#000000",
            "covered": [
                "top": Int(covered.top.rounded()), "bottom": Int(covered.bottom.rounded()),
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        else { return "window.__heelerRDConfig = {};" }
        return "window.__heelerRDConfig = \(json);"
    }

    static func viewerScript(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "viewer", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onStats: @MainActor ([String: Any]) -> Void
        var onFirstFrame: @MainActor () -> Void
        /// The one origin this view may load; the first navigation names it.
        private var allowedOrigin: String?

        init(
            onStats: @escaping @MainActor ([String: Any]) -> Void,
            onFirstFrame: @escaping @MainActor () -> Void
        ) {
            self.onStats = onStats
            self.onFirstFrame = onFirstFrame
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                return decisionHandler(.cancel)
            }
            if allowedOrigin == nil { allowedOrigin = Self.origin(of: url) }
            decisionHandler(Self.origin(of: url) == allowedOrigin ? .allow : .cancel)
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            if body["firstFrame"] as? Bool == true {
                onFirstFrame()
            } else {
                onStats(body)
            }
        }

        private static func origin(of url: URL) -> String? {
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return "\(scheme)://\(host):\(url.port ?? 0)"
        }
    }
}
