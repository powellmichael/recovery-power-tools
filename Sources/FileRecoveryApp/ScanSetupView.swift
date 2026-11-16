import SwiftUI

/// The one step between choosing a source and scanning it: what to look for,
/// how thoroughly, and a single Start button. It replaces a settings sidebar
/// that sat beside an empty results pane.
struct ScanSetupView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    /// Non-nil when earlier results are still held and can be returned to.
    let backToResults: (() -> Void)?

    private var isDevice: Bool {
        if case .device = viewModel.target { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    notices

                    SetupCard(title: "What to look for") {
                        MediaPresetSelector(viewModel: viewModel)
                    }

                    SetupCard(title: "How thoroughly") {
                        HStack(alignment: .top, spacing: 10) {
                            depthOption(
                                title: "Quick",
                                detail: "Finds files that are still intact. Much faster.",
                                systemImage: "hare",
                                isFast: true
                            )
                            depthOption(
                                title: "Deep",
                                detail: "Also tries to rebuild damaged files. Can take several times longer.",
                                systemImage: "tortoise",
                                isFast: false
                            )
                        }
                    }

                    if isDevice {
                        Label {
                            Text("macOS will ask for your password when the scan starts. Reading a drive directly needs an administrator's permission. The scan only reads; nothing on the drive is changed.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.green)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }

                    actions
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                viewModel.returnToSourceSelection()
            } label: {
                Label("Choose Another Source", systemImage: "chevron.backward")
            }
            .buttonStyle(.link)
            .disabled(!viewModel.canReturnToSourceSelection)

            VStack(alignment: .leading, spacing: 6) {
                Text("Set up your scan")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Label(viewModel.sourceLabel ?? "No source", systemImage: "externaldrive")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// Anything the user should read before starting: a failed attempt, an
    /// empty previous scan, a folder that cannot hold deleted files.
    @ViewBuilder private var notices: some View {
        if case .failed(let message) = viewModel.state {
            NoticeBand(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
        } else if viewModel.state == .finished, viewModel.items.isEmpty {
            NoticeBand(
                text: "The last scan found nothing. Try a Deep scan, or a wider choice of file types.",
                systemImage: "magnifyingglass",
                tint: .orange
            )
        }
        if let warning = viewModel.sourceWarning {
            NoticeBand(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let warning = viewModel.logWarning {
            NoticeBand(text: warning, systemImage: "clock.badge.exclamationmark", tint: .red)
        }
        if let status = viewModel.manifestStatus {
            NoticeBand(text: status, systemImage: "doc.text", tint: .blue)
        }
    }

    private func depthOption(title: String, detail: String, systemImage: String, isFast: Bool) -> some View {
        let selected = viewModel.fastScan == isFast
        return Button {
            viewModel.fastScan = isFast
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.07))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) scan. \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.scanButtonPressed()
            } label: {
                Label("Start Scan", systemImage: "magnifyingglass")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
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

            if let backToResults {
                Button("Back to Results", action: backToResults)
                    .controlSize(.large)
            }

            Spacer()

            Button("Open a Saved Session…") {
                viewModel.importManifest()
            }
            .buttonStyle(.link)
            .help("Open a saved list of found files and check it against this drive, without scanning again")
        }
    }
}

private struct SetupCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }
}

/// A full-width message band, used wherever the app has something to say
/// about the current source or the last operation.
struct NoticeBand: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
