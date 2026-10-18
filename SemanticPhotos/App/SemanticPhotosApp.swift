import SwiftUI
import UIKit

@main
struct SemanticPhotosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = "system"
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(colorScheme)
                .task { model.onLaunch() }
                .onOpenURL { model.handleOpenURL($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
    private var colorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_DARK_MODE"] == "1" { return .dark }
        #endif
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGTaskScheduler requires launch handlers before launch finishes (F2.8).
        AppModel.shared.background.registerOvernightHandler()
        return true
    }
}
