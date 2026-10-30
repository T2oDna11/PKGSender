import SwiftUI

@main
struct PKGSenderApp: App {
    @AppStorage("appTheme") private var appTheme = "charcoal"
    init() { USBBridgeServer.shared.start() }

    private var scheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(scheme)
        }
    }
}
