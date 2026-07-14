import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RecoveryViewModel()

    var body: some View {
        NavigationSplitView {
            Sidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            ResultsView(viewModel: viewModel)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Source")
                    .font(.headline)
                PathRow(label: viewModel.sourceLabel, placeholder: "No source selected")
                Menu {
                    if viewModel.externalDevices.isEmpty {
                        Text("No external drives found")
                    }
                    ForEach(viewModel.externalDevices) { device in
                        Button(device.displayName) {
                            viewModel.chooseDevice(device)
                        }
                    }
                    Divider()
                    Button("Refresh") {
                        viewModel.refreshDevices()
                    }
                } label: {
                    Label("Choose Drive", systemImage: "externaldrive")
                }
                Button {
                    viewModel.chooseSource()
                } label: {
                    Label("Choose File / Folder", systemImage: "folder.badge.gearshape")
                }

                if let warning = viewModel.sourceWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Destination")
                    .font(.headline)
                PathRow(label: viewModel.destinationURL?.lastPathComponent, placeholder: "No destination selected")
                Button {
                    viewModel.chooseDestination()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Media")
                    .font(.headline)
                ForEach(MediaKind.allCases) { kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { viewModel.selectedKinds.contains(kind) },
                        set: { _ in viewModel.toggleKind(kind) }
                    ))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    viewModel.startScan()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canScan)

                Button {
                    viewModel.recoverSelected()
                } label: {
                    Label("Recover", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!viewModel.canRecover)

                if viewModel.isScanActive {
                    Button {
                        viewModel.togglePause()
                    } label: {
                        Label(
                            viewModel.state == .paused ? "Resume" : "Pause",
                            systemImage: viewModel.state == .paused ? "play.circle" : "pause.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        viewModel.cancelScan()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Spacer()

            StatusBlock(viewModel: viewModel)
        }
        .padding(20)
        .onAppear {
            viewModel.refreshDevices()
        }
    }
}

private struct PathRow: View {
    let label: String?
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: label == nil ? "minus.circle" : "checkmark.circle")
                .foregroundStyle(label == nil ? Color.secondary : Color.green)
            Text(label ?? placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(label == nil ? .secondary : .primary)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBlock: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch viewModel.state {
            case .idle:
                Label("Ready", systemImage: "circle")
            case .scanning:
                Label("Scanning", systemImage: "waveform.path.ecg")
            case .paused:
                Label("Paused", systemImage: "pause.circle")
            case .recovering:
                Label("Recovering", systemImage: "tray.and.arrow.down")
            case .finished:
                Label("Finished", systemImage: "checkmark.circle")
            case .failed:
                Label("Needs Attention", systemImage: "exclamationmark.triangle")
            }

            ProgressView(value: viewModel.progress.fraction)
                .opacity(viewModel.isScanActive ? 1 : 0.35)

            Text("\(viewModel.items.count) item\(viewModel.items.count == 1 ? "" : "s") found")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(viewModel.selectedRecoveryIDs.count) selected")
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

private struct ResultsView: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recoverable Media")
                    .font(.title2.bold())
                Spacer()
                if !viewModel.items.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter by filename", text: Binding(
                            get: { viewModel.filenameFilter },
                            set: { viewModel.filenameFilter = $0 }
                        ))
                        .textFieldStyle(.plain)
                        if !viewModel.filenameFilter.isEmpty {
                            Button {
                                viewModel.filenameFilter = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: 240)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        viewModel.selectAllForRecovery()
                    } label: {
                        Label("Select All", systemImage: "checklist.checked")
                    }

                    Button {
                        viewModel.selectNoneForRecovery()
                    } label: {
                        Label("Select None", systemImage: "checklist.unchecked")
                    }
                }
                Text(totalSize)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)

            if let note = viewModel.scanNote {
                Label(note, systemImage: "info.circle.fill")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }

            if viewModel.items.isEmpty {
                EmptyResultsView()
            } else {
                HSplitView {
                    Table(viewModel.filteredItems, selection: Binding(
                        get: { viewModel.selectedItemID },
                        set: { viewModel.selectItem($0) }
                    ), sortOrder: Binding(
                        get: { viewModel.sortOrder },
                        set: { viewModel.sortOrder = $0 }
                    )) {
                        TableColumn("") { item in
                            Toggle("", isOn: Binding(
                                get: { viewModel.isSelectedForRecovery(item) },
                                set: { viewModel.setSelectedForRecovery(item, isSelected: $0) }
                            ))
                            .labelsHidden()
                        }
                        .width(34)

                        TableColumn("Type") { item in
                            Label(item.kind.rawValue, systemImage: icon(for: item.kind))
                        }
                        .width(min: 110, ideal: 130)

                        TableColumn("Filename", value: \.filenameLabel) { item in
                            Text(item.filenameLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(item.originalFilename == nil ? .secondary : .primary)
                        }
                        .width(min: 150, ideal: 200)

                        TableColumn("Offset") { item in
                            Text("0x\(String(item.byteOffset, radix: 16).uppercased())")
                                .font(.system(.body, design: .monospaced))
                        }
                        .width(min: 120, ideal: 150)

                        TableColumn("Size", value: \.byteLength) { item in
                            Text(item.sizeLabel)
                        }
                        .width(min: 90, ideal: 110)

                        TableColumn("Status") { item in
                            if let recoveredURL = item.recoveredURL {
                                Text(recoveredURL.lastPathComponent)
                                    .foregroundStyle(.green)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else if let recoveryError = item.recoveryError {
                                Text(recoveryError)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(recoveryError)
                            } else {
                                Text("Pending")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minWidth: 600)

                    PreviewPane(viewModel: viewModel)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private var totalSize: String {
        let visible = viewModel.filteredItems
        let total = visible.reduce(UInt64(0)) { $0 + $1.byteLength }
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        guard visible.count != viewModel.items.count else { return size }
        return "\(visible.count) of \(viewModel.items.count) — \(size)"
    }
}

private func icon(for kind: MediaKind) -> String {
    switch kind {
    case .jpeg, .png, .heic, .raw, .bmp: "photo"
    case .video, .avi, .wmv, .flv, .webm, .mpeg: "video"
    case .zip: "archivebox"
    }
}

private struct PreviewPane: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preview")
                .font(.headline)

            previewContent
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if let item = viewModel.selectedItem {
                VStack(alignment: .leading, spacing: 8) {
                    MetadataRow(label: "Type", value: item.kind.rawValue)
                    MetadataRow(label: "Filename", value: item.filenameLabel)
                    MetadataRow(label: "Size", value: item.sizeLabel)
                    MetadataRow(label: "Offset", value: "0x\(String(item.byteOffset, radix: 16).uppercased())")
                    MetadataRow(label: "Source", value: item.source.displayName)
                    MetadataRow(label: "Selected", value: viewModel.isSelectedForRecovery(item) ? "Yes" : "No")
                }
                .font(.callout)
            } else {
                Text("Select a result to inspect it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let image = viewModel.previewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(10)
        } else if let item = viewModel.selectedItem,
                  ![MediaKind.jpeg, .png, .heic, .bmp].contains(item.kind) {
            VStack(spacing: 10) {
                Image(systemName: icon(for: item.kind))
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("\(item.kind.rawValue) preview unavailable")
                    .foregroundStyle(.secondary)
            }
        } else if let previewError = viewModel.previewError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(previewError)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else if viewModel.selectedItem != nil {
            ProgressView()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct EmptyResultsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("No media found")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
