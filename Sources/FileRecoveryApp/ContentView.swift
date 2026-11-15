import AppKit
import AVKit
import SwiftUI

/// User-facing appearance preference. System follows the Mac's setting by
/// mapping to a nil preferredColorScheme.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = RecoveryViewModel()
    @State private var showsLiveResults = false
    @AppStorage("appearance") private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            if viewModel.target == nil {
                SourceSelectionView(viewModel: viewModel, appearanceRaw: $appearanceRaw)
            } else if viewModel.isScanActive {
                if showsLiveResults {
                    VStack(spacing: 0) {
                        ScanningView(viewModel: viewModel, compact: true) {
                            showsLiveResults = false
                        }
                        Divider()
                        ResultsView(viewModel: viewModel, appearanceRaw: $appearanceRaw)
                    }
                } else {
                    ScanningView(viewModel: viewModel) {
                        showsLiveResults = true
                    }
                }
            } else {
                // This pane contains configuration controls, not navigation
                // links. Keep it out of NavigationSplitView's sidebar hosting
                // so native buttons retain normal event handling as presets
                // update the configuration view.
                HSplitView {
                    Sidebar(viewModel: viewModel)
                        .frame(minWidth: 270, idealWidth: 310, maxWidth: 380)
                        .clipped()
                    ResultsView(viewModel: viewModel, appearanceRaw: $appearanceRaw)
                        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .onChange(of: viewModel.isScanActive) { _, active in
            if !active { showsLiveResults = false }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showFullSizePreview && viewModel.previewImage != nil },
            set: { viewModel.showFullSizePreview = $0 }
        )) {
            FullSizePreview(viewModel: viewModel)
        }
        .preferredColorScheme(appearance.colorScheme)
        .alert("Recovery complete", isPresented: Binding(
            get: { viewModel.showRecoveryCompletePrompt },
            set: { viewModel.showRecoveryCompletePrompt = $0 }
        )) {
            Button("Uncheck Recovered Files") { viewModel.uncheckRecoveredFiles() }
            Button("Keep Selected", role: .cancel) {}
        } message: {
            Text(recoveryCompleteMessage)
        }
    }

    private var recoveryCompleteMessage: String {
        let n = viewModel.justRecoveredCount
        var text = "Recovered \(n) file\(n == 1 ? "" : "s"). "
        if viewModel.recoveryFailureCount > 0 {
            let f = viewModel.recoveryFailureCount
            text += "\(f) file\(f == 1 ? "" : "s") could not be recovered. "
        }
        text += "Uncheck the recovered files so they're no longer selected?"
        return text
    }
}

/// Full-size image viewer: shows the image at its natural pixel size, with
/// scrolling when it exceeds the window.
struct FullSizePreview: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let item = viewModel.selectedItem {
                    let image = viewModel.previewImage
                    let dimensions = image.map { "\(Int($0.size.width)) × \(Int($0.size.height))" } ?? ""
                    Text(item.filenameLabel)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(dimensions)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.showFullSizePreview = false
                } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(12)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                if let image = viewModel.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: image.size.width, height: image.size.height)
                }
            }
            // Adapts to appearance; the old hardcoded black wash was wrong in
            // light mode.
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 600, idealWidth: 1000, minHeight: 400, idealHeight: 720)
    }
}

/// A quiet titled card, the sidebar's basic unit.
struct SidebarCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Sidebar: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        // The controls scroll; expanding a media category grows the content
        // rather than pushing the top of the sidebar out of view. Status stays
        // pinned to the bottom so scan progress is visible while scrolled.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SidebarCard(title: "Source") {
                        PathRow(
                            label: viewModel.sourceLabel,
                            placeholder: "No source selected",
                            systemImage: "externaldrive"
                        )
                        Button {
                            viewModel.returnToSourceSelection()
                        } label: {
                            Label("Choose Another Source", systemImage: "chevron.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Return to the source selection page")
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.canReturnToSourceSelection)

                        if let warning = viewModel.sourceWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let warning = viewModel.logWarning {
                            Label(warning, systemImage: "clock.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .help(warning)
                        }
                    }

                    SidebarCard(title: "Media") {
                        MediaPresetSelector(viewModel: viewModel)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Fast scan", isOn: Binding(
                            get: { viewModel.fastScan },
                            set: { viewModel.fastScan = $0 }
                        ))
                        .help("Much faster, but may miss or truncate badly damaged files. Intact files are unaffected.")

                        Button {
                            viewModel.scanButtonPressed()
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!viewModel.canScan)
                        .confirmationDialog(
                            "A filename filter is active",
                            isPresented: Binding(
                                get: { viewModel.showClearFilterPrompt },
                                set: { viewModel.showClearFilterPrompt = $0 }
                            )
                        ) {
                            Button("Clear filter and scan") { viewModel.confirmScan(clearFilter: true) }
                            Button("Keep filter and scan") { viewModel.confirmScan(clearFilter: false) }
                            Button("Cancel", role: .cancel) { viewModel.showClearFilterPrompt = false }
                        } message: {
                            Text("“\(viewModel.filenameFilter)” will hide results that don't match. Clear it to see everything the scan finds.")
                        }

                    }

                    SidebarCard(title: "File List") {
                        HStack(spacing: 6) {
                            Button {
                                viewModel.exportManifest()
                            } label: {
                                Label("Export…", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.items.isEmpty)
                            .help("Save these results so they can be recovered later without re-scanning")

                            Button {
                                viewModel.importManifest()
                            } label: {
                                Label("Import…", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.target == nil || viewModel.isScanActive)
                            .help("Open a saved list and check it against the selected drive")
                        }

                        if let status = viewModel.manifestStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            StatusBlock(viewModel: viewModel)
                .padding(14)
                .background(.quaternary.opacity(0.35))
        }
        .onAppear {
            viewModel.refreshDevices()
        }
    }
}

struct PathRow: View {
    let label: String?
    let placeholder: String
    var systemImage = "checkmark.circle"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: label == nil ? "minus.circle" : systemImage)
                .foregroundStyle(label == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Text(label ?? placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(label == nil ? .secondary : .primary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusBlock: View {
    @ObservedObject var viewModel: RecoveryViewModel

    private var stateLabel: (String, String) {
        switch viewModel.state {
        case .idle: ("Ready", "circle")
        case .scanning: ("Scanning", "waveform.path.ecg")
        case .paused: ("Paused", "pause.circle")
        case .recovering: ("Recovering", "tray.and.arrow.down")
        case .finished: ("Finished", "checkmark.circle")
        case .failed: ("Needs Attention", "exclamationmark.triangle")
        }
    }

    /// Elapsed scan time. Absent until a scan has run, and kept afterwards so
    /// the finished state still reports how long it took.
    @ViewBuilder private var elapsedText: some View {
        if let elapsed = viewModel.elapsedScanLabel {
            Text(elapsed)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Time spent scanning. Paused time is not counted.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(stateLabel.0, systemImage: stateLabel.1)
                    .font(.callout.weight(.medium))
                // Only the running clock needs a per-second redraw, and
                // TimelineView keeps that redraw local to this label instead of
                // republishing the whole view model once a second.
                if viewModel.scanStartedAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        elapsedText
                    }
                } else {
                    elapsedText
                }
                Spacer()
                if let percent = viewModel.progress.percentLabel, viewModel.progress.totalBytes > 0 {
                    Text(percent)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .help("Share of the scanned area read so far. Files are found unevenly, so this is an estimate.")
                }
            }

            ProgressView(value: viewModel.progress.fraction)
                .opacity(viewModel.isScanActive ? 1 : 0.35)

            if let bytes = viewModel.progress.byteLabel, viewModel.progress.totalBytes > 0 {
                Text(bytes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(viewModel.items.count) found · \(viewModel.selectedRecoveryIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .failed(let message) = viewModel.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            } else if viewModel.isScanActive {
                Text(viewModel.progress.currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }
}
