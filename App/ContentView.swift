import SwiftUI
import WebKit

/// Hosts the Glassday interface (Resources/index.html) full-screen and wires it to Apple Calendar.
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = WebModel()

    var body: some View {
        WebView(webView: model.webView)
            .ignoresSafeArea()
            .background(Color("LaunchBackground"))
            // The page's Light/Dark setting also drives the status bar, keyboard and pickers.
            .preferredColorScheme(model.scheme)
            .onOpenURL { model.open($0) }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: model.bridge.appBecameActive()
                // Never leave the screen pinned awake behind our back; the page
                // asks again when it is visible and a focus timer is still running.
                case .background: UIApplication.shared.isIdleTimerDisabled = false
                default: break
                }
            }
    }
}

final class WebModel: NSObject, ObservableObject, WKNavigationDelegate {
    let bridge = CalendarBridge()
    /// nil follows the system; set when the page picks Light or Dark in its own settings.
    @Published var scheme: ColorScheme?

    override init() {
        super.init()
        Alerts.shared.onOpenDay = { [weak self] day in self?.bridge.openDay(day) }
        bridge.onScheme = { [weak self] mode in
            self?.scheme = mode == "dark" ? .dark : mode == "light" ? .light : nil
        }
    }

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        installStateScript(controller)
        controller.add(bridge, name: "gd")
        config.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.bounces = false
        view.scrollView.isScrollEnabled = false      // the page scrolls inside itself; never pan the whole screen
        view.scrollView.keyboardDismissMode = .interactive
        view.allowsLinkPreview = false
        if #available(iOS 16.4, *) { view.isInspectable = true }

        bridge.webView = view
        observeKeyboard(view)
        NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification,
                                               object: nil, queue: .main) { [weak view] _ in
            view?.evaluateJavaScript("window.GDtext && GDtext(\(WebModel.textStep()))", completionHandler: nil)
        }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }()

    /// Hand the page its saved state before any of its scripts run.
    /// Re-run before every reload so the page never boots from a stale snapshot.
    private func installStateScript(_ controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let saved = UserDefaults.standard.string(forKey: CalendarBridge.stateKey) ?? ""
        let literal = (try? JSONEncoder().encode(saved)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let safe = literal.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        controller.addUserScript(WKUserScript(
            source: "window.GD_NATIVE=true;window.GD_TEXT=\(Self.textStep());window.GD_SAVED=\(safe);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
    }

    // MARK: Dynamic Type

    /// The page is laid out in fixed CSS px, so it follows the iOS text size by zooming its
    /// viewport (see GDtext in index.html). This is the zoom step for the current text size;
    /// the page caps it so its layout never gets narrower than 335 CSS px.
    static func textStep() -> Double {
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall: return 0.9
        case .small: return 0.94
        case .medium: return 0.97
        case .large: return 1.0
        case .extraLarge: return 1.05
        case .extraExtraLarge: return 1.1
        case .extraExtraExtraLarge: return 1.15
        case .accessibilityMedium: return 1.2
        case .accessibilityLarge: return 1.25
        default: return 1.3   // the larger accessibility sizes
        }
    }

    // MARK: navigation

    /// iOS can kill the web content process (usually under memory pressure while backgrounded).
    /// Without this the app comes back as a blank screen until it is force-quit.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridge.pageWillReload()
        installStateScript(webView.configuration.userContentController)
        webView.reload()
    }

    /// The page is a local file; anything else (a stray link) opens outside the app.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.isFileURL || url.scheme == "about" { return decisionHandler(.allow) }
        if action.navigationType == .linkActivated, ["http", "https", "mailto", "tel"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    /// Tell the page how tall the keyboard is, and stop iOS from shifting the whole web view up.
    private func observeKeyboard(_ view: WKWebView) {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak view] note in
            guard let view, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = view.convert(frame, from: nil)
            let overlap = max(0, view.bounds.maxY - local.minY)   // points; the page converts to CSS px
            view.scrollView.setContentOffset(.zero, animated: false)
            view.evaluateJavaScript("window.GDkb && GDkb(\(Int(overlap)))", completionHandler: nil)
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak view] _ in
            view?.scrollView.setContentOffset(.zero, animated: false)
            view?.evaluateJavaScript("window.GDkb && GDkb(0)", completionHandler: nil)
        }
        center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak view] _ in
            view?.scrollView.setContentOffset(.zero, animated: false)
        }
    }

    /// Widget taps open glassday://day/2026-11-03
    func open(_ url: URL) {
        // Exactly glassday://day/YYYY-MM-DD: one path component, nothing else.
        guard url.scheme == "glassday", url.host == "day", url.pathComponents.count == 2 else { return }
        bridge.openDay(url.pathComponents[1])
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
