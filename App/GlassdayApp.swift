import SwiftUI

@main
struct GlassdayApp: App {
    init() {
        Alerts.shared.install()   // before launch finishes, so tapping an alert can open its day
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
