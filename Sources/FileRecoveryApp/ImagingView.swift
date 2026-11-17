import AppKit
import SwiftUI

/// Copy a Drive: read a failing drive once into an image file, then recover
/// from the file. The drive is only ever read.
struct ImagingView: View {
    @ObservedObject var viewModel: ImagingViewModel
    let showHome: () -> Void
    /// Opens the finished image in Recover. Returns false if Recover is busy.
    let scanImage: (URL) -> Bool
    @State private var recoverBusy = false

    var body: some View {
        Group {
            switch viewModel.stage {
            case .setup, .failed: setup
            case .copying: copying
            case .done: done
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.refreshDevices() }
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
                    Text("Copy a drive")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Make an exact copy of a drive or card in one file, then recover from the copy. A drive that is failing is read once instead of over and over.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .failed(let message) = viewModel.stage {
                    NoticeBand(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    Button("Try Again") { viewModel.reset() }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Drive to copy")
                            .font(.headline)
                        Spacer()
                        if viewModel.isLoadingDevices {
                            ProgressView().controlSize(.small)
                        }
                        Button("Refresh") { viewModel.refreshDevices() }
                            .disabled(viewModel.isLoadingDevices)
                    }
                    if viewModel.devices.isEmpty, !viewModel.isLoadingDevices {
                        Text("No external drives found. Connect a drive or card, then choose Refresh.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.devices) { device in
                        DeviceChoiceRow(device: device, selected: viewModel.selectedDeviceID == device.id) {
                            viewModel.select(device)
                        }
                    }
                    Text("Choose a volume, not the entire drive, when you can: a scan of a volume's image can show original file names. An image of an entire drive is searched without them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Text("Where to save the image")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Button(viewModel.destination == nil ? "Choose…" : "Change…") { viewModel.chooseDestination() }
                            .disabled(viewModel.selectedDevice == nil)
                        if let destination = viewModel.destination {
                            Text(destination.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if let device = viewModel.selectedDevice {
                            Text("Needs \(size(device.size)) free, on a different drive.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose a drive first.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let problem = viewModel.destinationProblem {
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
                    Text("macOS will ask for your password when the copy starts. The drive is only read; nothing on it is changed. Parts that cannot be read are skipped and filled with zeros, so one bad spot does not stop the copy.")
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
                    Label("Copy Drive", systemImage: "square.and.arrow.down.on.square")
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
            Text("Copying \(viewModel.selectedDevice?.userFacingName ?? "drive")…")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            if progress.done > 0 {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 420)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(size(progress.done)) of \(size(progress.total))" + (viewModel.remainingLabel.map { " · \($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                ProgressView()
                Text("Waiting for permission to read the drive…")
                    .foregroundStyle(.secondary)
            }
            if progress.unreadableBytes > 0 {
                Label("\(size(progress.unreadableBytes)) could not be read so far and was filled with zeros", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Stop", role: .cancel) { viewModel.cancel() }
                .controlSize(.large)
            Text("Keep both drives connected. Stopping keeps the part copied so far.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done

    @ViewBuilder private var done: some View {
        if let result = viewModel.result, let destination = viewModel.destination {
            let complete = result.stoppedBecause == nil
            VStack(spacing: 16) {
                Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(complete ? .green : .orange)
                    .accessibilityHidden(true)
                Text(complete ? "Drive copied" : "Copy stopped early")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                VStack(spacing: 6) {
                    if let reason = result.stoppedBecause {
                        Text("\(reason) \(size(result.copied)) of \(size(result.total)) was copied and kept. It can still be scanned, but files beyond that point are not in it.")
                    } else {
                        Text("\(size(result.copied)) saved to \(destination.lastPathComponent).")
                    }
                    if result.unreadableBytes > 0 {
                        Text("\(size(result.unreadableBytes)) could not be read and was filled with zeros. Files that sat there may be damaged.")
                            .foregroundStyle(.orange)
                    }
                    if complete {
                        Text("You can now disconnect the drive and recover from the image.")
                    }
                    if recoverBusy {
                        Text("Recover Files is busy with another scan. Finish or stop it, then open the image from Recover Files.")
                            .foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)

                HStack(spacing: 12) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    .controlSize(.large)
                    Button("Copy Another Drive") { viewModel.reset() }
                        .controlSize(.large)
                    Button {
                        recoverBusy = !scanImage(destination)
                    } label: {
                        Label("Scan This Image", systemImage: "magnifyingglass")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(result.copied == 0)
                }
                .padding(.top, 6)
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
