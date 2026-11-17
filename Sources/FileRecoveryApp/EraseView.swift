import SwiftUI

/// Secure Erase: overwrite free space, chosen files, or a whole volume on an
/// external drive. The internal drive is never offered, and every job says
/// plainly what it cannot guarantee.
struct EraseView: View {
    @ObservedObject var viewModel: EraseViewModel
    let showHome: () -> Void
    @State private var confirmsJob = false
    @State private var confirmsVolume = false
    @State private var typedName = ""

    var body: some View {
        Group {
            switch viewModel.stage {
            case .setup, .failed:
                setup
            case .erasing, .verifying:
                working
            case .done:
                done
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.refreshDevices() }
        .sheet(isPresented: $confirmsVolume) { volumeConfirmation }
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Button(action: showHome) {
                        Label("All Tools", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    HelpLink(topic: "erase")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Secure erase")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Overwrite data on an external drive or card so recovery tools cannot bring it back.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .failed(let message) = viewModel.stage {
                    NoticeBand(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    Button("Try Again") { viewModel.reset() }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Picker("What to erase", selection: $viewModel.job) {
                        ForEach(EraseViewModel.Job.allCases) { job in
                            Text(job.label).tag(job)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(jobSummary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    if viewModel.job == .files {
                        fileChooser
                    } else {
                        deviceChooser
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .disabled(viewModel.stage != .setup)

                NoticeBand(text: limits, systemImage: "info.circle.fill", tint: .orange)

                Button(role: .destructive) {
                    if viewModel.job == .volume {
                        typedName = ""
                        confirmsVolume = true
                    } else {
                        confirmsJob = true
                    }
                } label: {
                    Label(startLabel, systemImage: "flame")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!viewModel.canStart)
                .confirmationDialog(confirmTitle, isPresented: $confirmsJob, titleVisibility: .visible) {
                    Button(viewModel.job == .files ? "Shred" : "Erase Free Space", role: .destructive) {
                        viewModel.start()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(confirmMessage)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    private var jobSummary: String {
        switch viewModel.job {
        case .freeSpace:
            "Destroys files you have already deleted. The files still on the drive are kept."
        case .files:
            "Destroys the files and folders you choose. Everything else on the drive is kept."
        case .volume:
            "Destroys everything on the volume and leaves it empty and ready to use."
        }
    }

    private var limits: String {
        switch viewModel.job {
        case .freeSpace:
            "Fills every free part of the drive with zeros, then removes the filler, so the drive is completely full while this runs. The names of deleted files can stay visible to recovery tools; their contents cannot be read. Afterwards a recovery scan checks the result, and macOS asks for your password to read the drive."
        case .files:
            "Each file is overwritten with zeros where it sits, then deleted. That is not a guarantee on flash storage (SD cards, USB sticks, SSDs), which can keep old copies where no software can reach, and earlier versions of a file may remain in the drive's free space. To be sure, erase the free space afterwards or erase the entire volume."
        case .volume:
            "The volume is formatted and then all of its space is overwritten with zeros. Flash storage (SD cards, USB sticks, SSDs) keeps a small reserve of memory that no app can reach, so no software can promise that every trace is gone. Afterwards a recovery scan checks the result, and macOS asks for your password to read the drive."
        }
    }

    private var startLabel: String {
        switch viewModel.job {
        case .freeSpace: "Erase Free Space…"
        case .files: "Shred…"
        case .volume: "Erase Volume…"
        }
    }

    private var confirmTitle: String {
        if viewModel.job == .files {
            return "Shred \(viewModel.files.count.formatted()) item\(viewModel.files.count == 1 ? "" : "s")?"
        }
        return "Erase the free space on \(viewModel.selectedDevice?.userFacingName ?? "this drive")?"
    }

    private var confirmMessage: String {
        viewModel.job == .files
            ? "The files, and everything inside the folders, are overwritten and deleted. They do not go to the Trash. This cannot be reversed."
            : "Deleted files on this drive will no longer be recoverable. This cannot be reversed. Files still on the drive are not affected."
    }

    private var deviceChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.job == .volume ? "Volume to erase" : "Drive")
                    .font(.headline)
                Spacer()
                if viewModel.isLoadingDevices {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") { viewModel.refreshDevices() }
                    .disabled(viewModel.isLoadingDevices)
            }

            if viewModel.candidates.isEmpty, !viewModel.isLoadingDevices {
                Text(viewModel.job == .freeSpace
                     ? "No mounted external drives found. Connect a drive or card, then choose Refresh. The Mac's internal drive is never listed."
                     : "No external drives found. Connect a drive or card, then choose Refresh. The Mac's internal drive is never listed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(viewModel.candidates) { device in
                DeviceChoiceRow(device: device, selected: viewModel.selectedDeviceID == device.id) {
                    viewModel.select(device)
                }
            }

            Text(viewModel.job == .freeSpace
                 ? "Only drives macOS can write to are listed. A Windows (NTFS) drive is read-only on a Mac, so erase its entire volume instead."
                 : "APFS and unformatted drives are not listed. Use Disk Utility to erase those.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.job == .volume, viewModel.selectedDevice != nil {
                Picker("Format as", selection: $viewModel.format) {
                    ForEach(EraseFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.top, 4)
            }
        }
    }

    private var fileChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Files and folders to shred")
                .font(.headline)
            if viewModel.files.isEmpty {
                Text("Nothing chosen yet. Only files on external drives and cards can be added.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(viewModel.files, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: url.hasDirectoryPath ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.secondary)
                    Text(url.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        viewModel.removeFile(url)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(url.lastPathComponent)")
                }
            }
            if let notice = viewModel.fileNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add Files or Folders…") { viewModel.chooseFiles() }
        }
    }

    /// A whole volume takes more than a click: the name has to be typed.
    private var volumeConfirmation: some View {
        let device = viewModel.selectedDevice
        let expected = viewModel.confirmationText
        return VStack(alignment: .leading, spacing: 14) {
            Label("Erase \(device?.userFacingName ?? "this volume")?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("Everything on this volume will be destroyed: \(device?.filesystemLabel ?? ""), \(ByteCountFormatter.string(fromByteCount: Int64(device?.size ?? 0), countStyle: .file)), \(device?.physicalName ?? device?.identifier ?? ""). It will be formatted as \(viewModel.format.label). This cannot be reversed, and the files cannot be recovered afterwards, by this app or any other.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Type “\(expected)” to confirm.")
                .font(.callout.weight(.medium))
            TextField(expected, text: $typedName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Volume name")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirmsVolume = false }
                    .keyboardShortcut(.cancelAction)
                Button("Erase Volume", role: .destructive) {
                    confirmsVolume = false
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(expected.isEmpty || typedName != expected)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    // MARK: - Working

    private var working: some View {
        let verifying = viewModel.stage == .verifying
        return VStack(spacing: 18) {
            Text(verifying ? "Checking that nothing can be recovered…" : workingTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            if verifying {
                ProgressView(value: viewModel.checkFraction)
                    .frame(maxWidth: 420)
                Text("The erase is finished. A recovery scan is now searching the drive for anything left.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let fraction = viewModel.progress.fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 420)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(viewModel.progress.done), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(viewModel.progress.total), countStyle: .file)) overwritten")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
                Text("Preparing…")
                    .foregroundStyle(.secondary)
            }
            Button(verifying ? "Skip Check" : "Stop", role: .cancel) { viewModel.cancel() }
                .controlSize(.large)
            if !verifying {
                Text("Keep the drive connected. Unplugging it now can damage its contents.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workingTitle: String {
        switch viewModel.job {
        case .freeSpace: "Overwriting free space…"
        case .files: "Shredding files…"
        case .volume: "Erasing volume…"
        }
    }

    // MARK: - Done

    private var done: some View {
        let outcome = viewModel.outcome
        return VStack(spacing: 16) {
            Image(systemName: outcome.succeeded ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(outcome.succeeded ? .green : .orange)
                .accessibilityHidden(true)
            Text(outcome.headline)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            if let count = outcome.stillRecoverable {
                Label(
                    count == 0
                        ? "Recovery check: 0 recoverable files found"
                        : "Recovery check: \(count.formatted()) file\(count == 1 ? "" : "s") could still be found. Erase the entire volume to remove them.",
                    systemImage: count == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.title3.weight(.medium))
                .foregroundStyle(count == 0 ? .green : .orange)
                .multilineTextAlignment(.center)
            }
            if let note = outcome.checkNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(outcome.details.prefix(8), id: \.self) { line in
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if outcome.details.count > 8 {
                    Text("…and \(outcome.details.count - 8) more.")
                }
            }
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button("Erase Something Else") { viewModel.reset() }
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

/// One selectable drive or volume in a list. Shared by the tools that act on
/// a whole device.
struct DeviceChoiceRow: View {
    let device: ExternalDevice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Image(systemName: "externaldrive")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.userFacingName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(device.isWholeDisk ? "Entire drive" : device.filesystemLabel) · \(ByteCountFormatter.string(fromByteCount: Int64(device.size), countStyle: .file)) · \(device.physicalName ?? device.identifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.userFacingName), \(device.isWholeDisk ? "entire drive" : device.filesystemLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
