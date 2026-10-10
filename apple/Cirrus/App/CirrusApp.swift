import CirrusKit
import SwiftUI

@main
struct CirrusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.orange)
        }
        #if os(macOS)
            .defaultSize(width: 1180, height: 780)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button(L("Refresh", "刷新")) { Task { await model.refresh() } }
                        .keyboardShortcut("r")
                }
            }
        #endif

        #if os(macOS)
            Settings {
                NavigationStack { SettingsView() }
                    .environment(model)
                    .frame(width: 560, height: 640)
            }
        #endif
    }
}
