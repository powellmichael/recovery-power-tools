import AppKit
import SwiftUI

/// Verified Copy: copy a camera card to one or two drives and prove every
/// file arrived intact before the card is formatted.
struct CardCopyView: View {
    @ObservedObject var viewModel: CardCopyViewModel
    let showHome: () -> Void

    var body: some View {
        Group {
            switch viewModel.stage {
            case .setup, .failed: setup
            case .copying: copying
            case .done: done
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: showHome) {
                    Label("All Tools", systemImage: "chevron.backward")
                }
                .buttonStyle(.link)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy a card safely")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Copy a camera card to one or two drives, then check every copied file against the original, so you know it is safe to format the card.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .failed(let message) = viewModel.stage {
                    NoticeBand(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    Button("Try Again") { viewModel.reset() }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Copy from")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Button(viewModel.source == nil ? "Choose Card or Folder…" : "Change…") { viewModel.chooseSource() }
                        if let source = viewModel.source {
                            Label(source.path, systemImage: "sdcard")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Divider()

                    Text("Copy to")
                        .font(.headline)
                    if viewModel.destinations.isEmpty {
                        Text("Choose one or two folders on other drives. Two copies on two drives protect you if one drive fails.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(viewModel.destinations, id: \.self) { destination in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                            Text(destination.appendingPathComponent(viewModel.folderName).path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                viewModel.removeDestination(destination)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(destination.lastPathComponent)")
                        }
                    }
                    if viewModel.destinations.count < CardCopyViewModel.maxDestinations {
                        Button(viewModel.destinations.isEmpty ? "Add Destination…" : "Add a Second Destination…") {
                            viewModel.addDestination()
                        }
                    }
                    if let problem = viewModel.problem {
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .disabled(viewModel.stage != .setup)

                Label {
                    Text("Nothing on the card is changed or removed. The files go into a new folder in each destination, with their folders and dates kept. Hidden system files are not copied.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    viewModel.start()
                } label: {
                    Label("Copy and Verify", systemImage: "checkmark.seal")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canStart)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Copying

    private var copying: some View {
        let progress = viewModel.progress
        return VStack(spacing: 18) {
            Text("Copying and checking…")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 420)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(progress.filesDone.formatted()) of \(progress.fileCount.formatted()) files" + (viewModel.remainingLabel.map { " · \($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(progress.currentFile)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            } else {
                ProgressView()
                Text("Listing files…")
                    .foregroundStyle(.secondary)
            }
            Button("Stop", role: .cancel) { viewModel.cancel() }
                .controlSize(.large)
            Text("Keep the card and the drives connected. Do not format the card until this finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done

    private var done: some View {
        let report = viewModel.report
        let safe = report.everythingVerified
        return VStack(spacing: 16) {
            Image(systemName: safe ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(safe ? .green : .orange)
                .accessibilityHidden(true)
            Text(safe ? "All \(report.fileCount.formatted()) files copied and verified" : "Do not format the card yet")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                if safe {
                    Text("\(size(report.bytes)) in \(report.folders.count == 1 ? "one copy" : "\(report.folders.count) copies"). Every copy was read back from its drive and matches the original. It is safe to erase or format the card.")
                } else {
                    Text("\(report.verified.formatted()) of \(report.fileCount.formatted()) files were copied and verified\(report.stopped ? " before the copy was stopped" : ""). The rest are only on the card.")
                }
                Text("A list of checksums, \(VerifiedCopier.manifestName), was saved with each copy so it can be checked again later.")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)

            if !report.failures.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(report.failures.prefix(6), id: \.self) { failure in
                        Text(failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if report.failures.count > 6 {
                        Text("…and \(report.failures.count - 6) more.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(report.folders)
                }
                .controlSize(.large)
                .disabled(report.folders.isEmpty)
                Button("Copy Another Card") { viewModel.reset() }
                    .controlSize(.large)
                Button("All Tools") {
                    viewModel.reset()
                    showHome()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
