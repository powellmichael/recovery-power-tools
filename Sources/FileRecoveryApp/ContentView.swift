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

/// Which tool the window is showing. Home is the launch screen; each tool
/// owns everything below its own case.
enum AppRoute: Equatable {
    case home
    case recover
    case duplicates
    case erase
    case image
    case cardCopy
}

struct ContentView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @StateObject private var duplicates = DuplicatesViewModel()
    @StateObject private var erase = EraseViewModel()
    @StateObject private var imaging = ImagingViewModel()
    @StateObject private var cardCopy = CardCopyViewModel()
    @State private var route: AppRoute = .home
    @State private var showsLiveResults = false
    /// True while the user is back on the setup step with results still held,
    /// so "Scan Again" doesn't have to throw the current results away first.
    @State private var showsScanSetup = false
    @AppStorage("appearance") private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    /// Crash reports found at launch, waiting for the user's decision.
    @State private var crashReports: [URL] = []

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            switch route {
            case .home:
                HomeView(
                    openRecover: { route = .recover },
                    openDuplicates: { route = .duplicates },
                    openErase: { route = .erase },
                    openImage: { route = .image },
                    openCardCopy: { route = .cardCopy }
                )
            case .recover:
                recoverFlow
            case .duplicates:
                DuplicatesView(viewModel: duplicates) { route = .home }
            case .erase:
                EraseView(viewModel: erase) { route = .home }
            case .cardCopy:
                CardCopyView(viewModel: cardCopy) { route = .home }
            case .image:
                ImagingView(viewModel: imaging, showHome: { route = .home }) { url in
                    guard viewModel.openImage(url) else { return false }
                    showsScanSetup = false
                    route = .recover
                    return true
                }
            }
        }
        .onChange(of: viewModel.isScanActive) { _, active in
            if active {
                showsScanSetup = false
            } else {
                showsLiveResults = false
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showFullSizePreview && viewModel.previewImage != nil },
            set: { viewModel.showFullSizePreview = $0 }
        )) {
            FullSizePreview(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showRecoveryCompletePrompt },
            set: { viewModel.showRecoveryCompletePrompt = $0 }
        )) {
            RecoveryCompleteSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showLicensePrompt },
            set: { viewModel.showLicensePrompt = $0 }
        )) {
            LicenseSheet(viewModel: viewModel)
        }
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { hasSeenWelcome = !$0 })) {
            WelcomeSheet { hasSeenWelcome = true }
        }
        .task {
            // Only finds anything if the user opted in.
            crashReports = CrashReports.pending()
        }
        .alert(
            "Recovery Power Tools quit unexpectedly last time",
            isPresented: Binding(get: { !crashReports.isEmpty && hasSeenWelcome }, set: { if !$0 { crashReports = [] } })
        ) {
            if CrashReports.supportEmail != nil {
                Button("Send Report…") {
                    if !CrashReports.compose(crashReports) {
                        NSWorkspace.shared.activateFileViewerSelecting(crashReports)
                    }
                }
            }
            Button("Show Report in Finder") { NSWorkspace.shared.activateFileViewerSelecting(crashReports) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(CrashReports.supportEmail != nil
                 ? "Sending the report helps fix the problem. It opens as an email you can read before sending. It describes the app and your Mac, not your files."
                 : "macOS saved a report of what went wrong. You can look at it, and attach it if you contact support.")
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    /// Recover is a straight line: choose a source, set up the scan, watch it
    /// run, review the results. Each step gets the whole window.
    @ViewBuilder private var recoverFlow: some View {
        if viewModel.target == nil {
            SourceSelectionView(viewModel: viewModel) { route = .home }
        } else if viewModel.isScanActive {
            if showsLiveResults {
                VStack(spacing: 0) {
                    ScanningView(viewModel: viewModel, compact: true) {
                        showsLiveResults = false
                    }
                    Divider()
                    ResultsView(viewModel: viewModel, scanAgain: nil)
                }
            } else {
                ScanningView(viewModel: viewModel) {
                    showsLiveResults = true
                }
            }
        } else if viewModel.items.isEmpty || showsScanSetup {
            ScanSetupView(
                viewModel: viewModel,
                backToResults: viewModel.items.isEmpty ? nil : { showsScanSetup = false }
            )
        } else {
            ResultsView(viewModel: viewModel) { showsScanSetup = true }
        }
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
