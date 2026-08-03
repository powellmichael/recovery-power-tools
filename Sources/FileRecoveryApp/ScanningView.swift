import AppKit
import SwiftUI

/// A focused state for work that can run for hours. Configuration and results
/// controls disappear so progress, pause, and cancellation are unambiguous.
struct ScanningView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var showsCancelConfirmation = false

    private var isPaused: Bool { viewModel.state == .paused }
    private var isVerifying: Bool { !viewModel.canPauseScan }

    private var title: String {
        if isVerifying { return "Verifying saved file list" }
        if isPaused { return "Scan paused" }
        return "Scanning \(viewModel.sourceLabel ?? "your source")"
    }

    private var detail: String {
        if isVerifying {
            return viewModel.manifestStatus ?? "Checking that saved files still match this drive…"
        }
        if isPaused {
            return "Your place is saved. Resume whenever you are ready."
        }
        return viewModel.scanNote ?? "Preparing the drive and locating recoverable space…"
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            Circle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: 620, height: 620)
                .blur(radius: 110)
                .offset(x: 380, y: -320)
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 28) {
                    statusHeader
                    progressCard
                    controls

                    Label("Read-only scan — the source drive is never modified", systemImage: "lock.shield.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 48)
                .padding(.vertical, 64)
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog(
            "Stop this scan?",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Scan", role: .destructive) {
                viewModel.cancelScan()
            }
            Button("Keep Scanning", role: .cancel) {}
        } message: {
            Text("Files found so far will remain available, but the rest of the source will not be searched.")
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(isPaused ? Color.orange.gradient : Color.accentColor.gradient)
                    .frame(width: 92, height: 92)
                    .shadow(
                        color: (isPaused ? Color.orange : Color.accentColor).opacity(0.24),
                        radius: 18,
                        y: 8
                    )

                Image(systemName: isVerifying ? "checkmark.shield.fill" : (isPaused ? "pause.fill" : "magnifyingglass"))
                    .font(.system(size: 35, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620)
            }
        }
    }

    private var progressCard: some View {
        VStack(spacing: 22) {
            if viewModel.progress.totalBytes > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(viewModel.progress.percentLabel ?? "0%")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    elapsedTime
                }

                ProgressView(value: viewModel.progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(isPaused ? .orange : .accentColor)
                    .scaleEffect(x: 1, y: 1.7)

                HStack {
                    Text(viewModel.progress.byteLabel ?? "Preparing…")
                    Spacer()
                    Text(viewModel.progress.currentPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .padding(.vertical, 10)
                Text(isVerifying ? "Reading drive metadata…" : "Preparing scan…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 0) {
                scanStat(value: "\(viewModel.items.count)", label: "Files found")
                Divider().frame(height: 42)
                scanStat(value: viewModel.selectedMediaPreset.label, label: "Media")
                Divider().frame(height: 42)
                scanStat(value: viewModel.fastScan ? "Fast" : "Deep", label: "Scan mode")
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    @ViewBuilder private var elapsedTime: some View {
        if viewModel.scanStartedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                elapsedLabel
            }
        } else {
            elapsedLabel
        }
    }

    private var elapsedLabel: some View {
        Label(viewModel.elapsedScanLabel ?? "0s", systemImage: "clock")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func scanStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if viewModel.canPauseScan {
                Button {
                    viewModel.togglePause()
                } label: {
                    Label(isPaused ? "Resume Scan" : "Pause Scan", systemImage: isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 125)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
            }

            Button(role: .destructive) {
                showsCancelConfirmation = true
            } label: {
                Label(isVerifying ? "Cancel" : "Stop Scan", systemImage: "xmark")
                    .frame(minWidth: 110)
            }
            .controlSize(.large)
        }
    }
}

private struct ScanningViewPreviews: PreviewProvider {
    static var previews: some View {
        let viewModel = RecoveryViewModel(
            recoveryLogURL: URL(fileURLWithPath: "/tmp/file-recovery-preview/recovered.json"),
            reviewLogURL: URL(fileURLWithPath: "/tmp/file-recovery-preview/review.json")
        )
        viewModel.target = .path(URL(fileURLWithPath: "/Volumes/Photo Archive"))
        viewModel.state = .paused
        viewModel.progress = ScanProgress(
            bytesScanned: 539_000_000_000,
            totalBytes: 842_000_000_000,
            currentPath: "Photo Archive"
        )
        return ScanningView(viewModel: viewModel)
            .frame(width: 1180, height: 760)
    }
}
