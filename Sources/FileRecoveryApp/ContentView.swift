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
                PathRow(url: viewModel.sourceURL, placeholder: "No source selected")
                Button {
                    viewModel.chooseSource()
                } label: {
                    Label("Choose Source", systemImage: "externaldrive")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Destination")
                    .font(.headline)
                PathRow(url: viewModel.destinationURL, placeholder: "No destination selected")
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
                    viewModel.recoverAll()
                } label: {
                    Label("Recover", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!viewModel.canRecover)

                if viewModel.state == .scanning {
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
    }
}

private struct PathRow: View {
    let url: URL?
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: url == nil ? "minus.circle" : "checkmark.circle")
                .foregroundStyle(url == nil ? Color.secondary : Color.green)
            Text(url?.lastPathComponent ?? placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(url == nil ? .secondary : .primary)
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
            case .recovering:
                Label("Recovering", systemImage: "tray.and.arrow.down")
            case .finished:
                Label("Finished", systemImage: "checkmark.circle")
            case .failed:
                Label("Needs Attention", systemImage: "exclamationmark.triangle")
            }

            ProgressView(value: viewModel.progress.fraction)
                .opacity(viewModel.state == .scanning ? 1 : 0.35)

            Text("\(viewModel.items.count) item\(viewModel.items.count == 1 ? "" : "s") found")
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .failed(let message) = viewModel.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if viewModel.state == .scanning {
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
                Text(totalSize)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)

            if viewModel.items.isEmpty {
                EmptyResultsView()
            } else {
                Table(viewModel.items, selection: $viewModel.selectedItemID) {
                    TableColumn("Type") { item in
                        Label(item.kind.rawValue, systemImage: icon(for: item.kind))
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Offset") { item in
                        Text("0x\(String(item.byteOffset, radix: 16).uppercased())")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Size") { item in
                        Text(item.sizeLabel)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Status") { item in
                        if let recoveredURL = item.recoveredURL {
                            Text(recoveredURL.lastPathComponent)
                                .foregroundStyle(.green)
                        } else {
                            Text("Pending")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private var totalSize: String {
        let total = viewModel.items.reduce(UInt64(0)) { $0 + $1.byteLength }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private func icon(for kind: MediaKind) -> String {
        switch kind {
        case .jpeg, .png, .heic: "photo"
        case .video: "video"
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
