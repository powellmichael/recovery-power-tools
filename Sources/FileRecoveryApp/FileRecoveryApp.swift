import AppKit
import SwiftUI

@main
struct FileRecoveryApp: App {
    /// Owned here rather than by ContentView so the menu bar commands can
    /// reach the same state the window shows.
    @StateObject private var viewModel = RecoveryViewModel()

    init() {
        // Bare executables (swift run) launch as background processes: the
        // window shows but the app never activates, so it gets no key events.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Recovery Power Tools") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.titleBar)
        .commands {
            // One window owns one scan. Replacing New also removes New Window,
            // which would open a second view onto the same state.
            CommandGroup(replacing: .newItem) {
                Button("Open Session…") { viewModel.importManifest() }
                    .keyboardShortcut("o")
                    .disabled(viewModel.target == nil || viewModel.isScanActive)
                Button("Save Session…") { viewModel.exportManifest() }
                    .keyboardShortcut("s")
                    .disabled(viewModel.items.isEmpty)
            }

            CommandMenu("Recovery") {
                Button("Start Scan") { viewModel.scanButtonPressed() }
                    .keyboardShortcut("r")
                    .disabled(!viewModel.canScan)
                Button(viewModel.state == .paused ? "Resume Scan" : "Pause Scan") { viewModel.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(!viewModel.canPauseScan)
                Button("Resume Stopped Scan") { viewModel.resumeScan() }
                    .disabled(viewModel.resumePoint == nil || viewModel.isScanActive || viewModel.state == .recovering)

                Divider()

                Button("Select All Shown for Recovery") { viewModel.selectAllForRecovery() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(viewModel.items.isEmpty)
                Button("Clear Recovery Selection") { viewModel.selectNoneForRecovery() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(viewModel.selectedRecoveryIDs.isEmpty)
                Button("Recover Selected…") { viewModel.recoverSelected() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!viewModel.canRecover)

                Divider()

                Button("Choose Another Source") { viewModel.returnToSourceSelection() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(viewModel.target == nil || !viewModel.canReturnToSourceSelection)
            }

            CommandGroup(replacing: .help) {
                HelpCommands()
            }
        }

        Window("Recovery Power Tools Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 860, height: 620)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

/// App-wide preferences. Appearance lived in two separate toolbars before;
/// a setting that changes rarely belongs here, not on every screen.
struct SettingsView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @AppStorage("appearance") private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage(CrashReports.enabledKey) private var crashReports = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearancePreference.allCases) { preference in
                    Label(preference.label, systemImage: preference.systemImage)
                        .tag(preference.rawValue)
                }
            }
            .pickerStyle(.inline)

            LicenseSettingsSection(viewModel: viewModel)

            Section("Crash Reports") {
                Toggle("Offer to send a report if the app quits unexpectedly", isOn: $crashReports)
                Text("When this is on, the app looks for its own crash report the next time it opens and asks whether you want to send it. Nothing is sent without you choosing to. A report describes the app and your Mac (model, macOS version, and folder paths, which include your user name). It does not contain your files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .preferredColorScheme((AppearancePreference(rawValue: appearanceRaw) ?? .system).colorScheme)
    }
}

/// The Help menu. A view, so it can reach openWindow.
private struct HelpCommands: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("helpTopic") private var topicID = HelpContent.topics[0].id
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        Button("Recovery Power Tools Help") { openWindow(id: "help") }
            .keyboardShortcut("?")
        Button("Why Can't I Find My File?") {
            topicID = HelpContent.cannotFindID
            openWindow(id: "help")
        }
        Divider()
        Button("Show Welcome Guide") { hasSeenWelcome = false }
    }
}
