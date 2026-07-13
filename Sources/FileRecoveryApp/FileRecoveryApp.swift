import AppKit
import SwiftUI

@main
struct FileRecoveryApp: App {
    init() {
        // Bare executables (swift run) launch as background processes: the
        // window shows but the app never activates, so it gets no key events.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.titleBar)
    }
}
