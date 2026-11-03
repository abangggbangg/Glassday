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
            .onOpenURL { model.open($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.bridge.appBecameActive() }
            }
    }
}

final class WebModel: ObservableObject {
    let bridge = CalendarBridge()

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // Hand the page its saved state before any of its scripts run.
        let saved = UserDefaults.standard.string(forKey: CalendarBridge.stateKey) ?? ""
        let literal = (try? JSONEncoder().encode(saved)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        controller.addUserScript(WKUserScript(
            source: "window.GD_NATIVE=true;window.GD_SAVED=\(literal);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        controller.add(bridge, name: "gd")
        config.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: config)
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
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }()

    /// Tell the page how tall the keyboard is, and stop iOS from shifting the whole web view up.
    private func observeKeyboard(_ view: WKWebView) {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak view] note in
            guard let view, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = view.convert(frame, from: nil)
            let overlap = max(0, view.bounds.maxY - local.minY)
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
        guard url.scheme == "glassday", url.host == "day" else { return }
        bridge.openDay(url.lastPathComponent)
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
