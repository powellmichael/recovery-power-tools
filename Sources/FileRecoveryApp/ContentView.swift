import AppKit
import AVKit
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
        .sheet(isPresented: Binding(
            get: { viewModel.showFullSizePreview && viewModel.previewImage != nil },
            set: { viewModel.showFullSizePreview = $0 }
        )) {
            FullSizePreview(viewModel: viewModel)
        }
    }
}

/// Full-size image viewer: shows the image at its natural pixel size, with
/// scrolling when it exceeds the window.
private struct FullSizePreview: View {
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
            .background(.black.opacity(0.6))
        }
        .frame(minWidth: 600, idealWidth: 1000, minHeight: 400, idealHeight: 720)
    }
}

private struct Sidebar: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        // The controls scroll; expanding a media category grows the content
        // rather than pushing the top of the sidebar out of view. Status stays
        // pinned to the bottom so scan progress is visible while scrolled.
        VStack(spacing: 0) {
            ScrollView {
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

                        if let warning = viewModel.logWarning {
                            Label(warning, systemImage: "clock.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .help(warning)
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
                        MediaFilterList(viewModel: viewModel)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Save as ZIP", isOn: Binding(
                            get: { viewModel.saveAsZip },
                            set: { viewModel.saveAsZip = $0 }
                        ))

                        if viewModel.saveAsZip {
                            TextField("ZIP name (optional)", text: Binding(
                                get: { viewModel.zipFileName },
                                set: { viewModel.zipFileName = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            viewModel.scanButtonPressed()
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
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

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("File List")
                            .font(.headline)

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

                        if let status = viewModel.manifestStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            StatusBlock(viewModel: viewModel)
                .padding(20)
        }
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

            if let percent = viewModel.progress.percentLabel, viewModel.progress.totalBytes > 0 {
                HStack(spacing: 6) {
                    Text(percent)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if let bytes = viewModel.progress.byteLabel {
                        Text(bytes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Share of the scanned area read so far. Files are found unevenly, so this is an estimate.")
            }

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
                    Picker("", selection: Binding(
                        get: { viewModel.viewMode },
                        set: { viewModel.viewMode = $0 }
                    )) {
                        ForEach(ResultsViewMode.allCases) { mode in
                            Image(systemName: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 90)
                    .labelsHidden()
                    .help("Switch between list and gallery")

                    Picker("", selection: Binding(
                        get: { viewModel.recoveredVisibility },
                        set: { viewModel.recoveredVisibility = $0 }
                    )) {
                        ForEach(RecoveredVisibility.allCases) { visibility in
                            Text(visibility.rawValue).tag(visibility)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .labelsHidden()

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
                    .help(viewModel.duplicateCount > 0
                          ? "Selects everything except \(viewModel.duplicateCount) duplicate\(viewModel.duplicateCount == 1 ? "" : "s")"
                          : "Selects every visible result")

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
                    Group {
                        if viewModel.viewMode == .gallery {
                            GalleryView(viewModel: viewModel)
                        } else {
                            resultsTable
                        }
                    }
                    .frame(minWidth: 600)

                    if viewModel.isPreviewPaneVisible {
                        PreviewPane(viewModel: viewModel)
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private var resultsTable: some View {
        Table(viewModel.filteredItems, selection: Binding(
                        get: { viewModel.tableSelection },
                        set: { viewModel.setTableSelection($0) }
                    ), sortOrder: Binding(
                        get: { viewModel.sortOrder },
                        set: { viewModel.sortOrder = $0 }
                    )) {
                        TableColumn("") { item in
                            Toggle("", isOn: Binding(
                                get: { viewModel.isSelectedForRecovery(item) },
                                set: { viewModel.setSelectedForRecoveryRespectingSelection(item, isSelected: $0) }
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

                        TableColumn("Preview") { item in
                            if item.kind.isPreviewable || item.kind.isVideoPreviewable {
                                Button {
                                    viewModel.showDetails(for: item)
                                } label: {
                                    Image(systemName: item.kind.isVideoPreviewable ? "play.rectangle" : "photo")
                                        .foregroundStyle(.tint)
                                }
                                .buttonStyle(.plain)
                                .help("Show preview")
                            }
                        }
                        .width(52)

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
                            } else if item.previouslyRecovered {
                                Text("Recovered previously")
                                    .foregroundStyle(.orange)
                            } else if let stale = viewModel.staleReason(for: item) {
                                Text(stale.rawValue)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                                    .help("This data changed since the list was saved, so it can no longer be recovered")
                            } else if item.isDuplicate {
                                Text("Duplicate")
                                    .foregroundStyle(.purple)
                                    .help("Same first 4 KB and size as an earlier result")
                            } else {
                                Text("Pending")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        TableColumn("Details") { item in
                            Button {
                                viewModel.toggleDetails(for: item)
                            } label: {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .help("Show or hide details")
                        }
                        .width(48)
        }
        .contextMenu(forSelectionType: RecoveredItem.ID.self) { ids in
            if !ids.isEmpty {
                let count = viewModel.recoverableCount(in: ids)
                Button("Mark \(count) for Recovery") {
                    viewModel.setSelectedForRecovery(ids: ids, isSelected: true)
                }
                .disabled(count == 0)

                Button("Remove \(ids.count) from Recovery") {
                    viewModel.setSelectedForRecovery(ids: ids, isSelected: false)
                }
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

/// Media kinds grouped into collapsible categories. A category's own toggle
/// selects or clears every kind in it; the box is filled when only some are on.
private struct MediaFilterList: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var expanded: Set<MediaCategory> = [.images]

    var body: some View {
        ForEach(MediaCategory.allCases) { category in
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(category) },
                set: { isOpen in
                    if isOpen { expanded.insert(category) } else { expanded.remove(category) }
                }
            )) {
                ForEach(category.kinds) { kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { viewModel.selectedKinds.contains(kind) },
                        set: { _ in viewModel.toggleKind(kind) }
                    ))
                }
            } label: {
                Toggle(isOn: Binding(
                    get: { viewModel.allSelected(in: category) },
                    set: { viewModel.setKinds(in: category, on: $0) }
                )) {
                    HStack(spacing: 6) {
                        Text(category.rawValue)
                        if viewModel.someSelected(in: category), !viewModel.allSelected(in: category) {
                            Text("\(category.kinds.filter(viewModel.selectedKinds.contains).count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private func icon(for kind: MediaKind) -> String {
    switch kind {
    case .jpeg, .png, .heic, .raw, .bmp: "photo"
    case .video, .avi, .wmv, .flv, .webm, .mpeg: "video"
    case .zip: "archivebox"
    }
}

private struct GalleryView: View {
    @ObservedObject var viewModel: RecoveryViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(viewModel.filteredItems) { item in
                    GalleryCell(viewModel: viewModel, item: item)
                        .onAppear { viewModel.requestThumbnail(for: item) }
                }
            }
            .padding(14)
        }
    }
}

private struct GalleryCell: View {
    @ObservedObject var viewModel: RecoveryViewModel
    let item: RecoveredItem

    private var isSelected: Bool { viewModel.tableSelection.contains(item.id) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Button {
                    // Modifiers are read at click time: SwiftUI buttons don't
                    // report them, and a plain click must keep toggling the
                    // preview pane as it always has.
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.shift) {
                        viewModel.extendSelection(to: item)
                    } else if flags.contains(.command) {
                        viewModel.toggleSelection(item)
                    } else {
                        viewModel.toggleDetails(for: item)
                    }
                } label: {
                    thumbnail
                        .frame(maxWidth: .infinity)
                        .frame(height: 130)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Click to show or hide details. Shift-click to select a range, Command-click to add one.")

                Toggle("", isOn: Binding(
                    get: { viewModel.isSelectedForRecovery(item) },
                    set: { viewModel.setSelectedForRecoveryRespectingSelection(item, isSelected: $0) }
                ))
                .labelsHidden()
                .padding(6)
            }

            Text(item.filenameLabel)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(item.originalFilename == nil ? .secondary : .primary)

            Text(item.sizeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if item.recoveredURL != nil {
                Label("Recovered", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if item.previouslyRecovered {
                Label("Recovered previously", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contextMenu {
            // A right-click on an unselected cell acts on that cell alone.
            let ids = viewModel.tableSelection.contains(item.id) ? viewModel.tableSelection : [item.id]
            let count = viewModel.recoverableCount(in: ids)
            Button("Mark \(count) for Recovery") {
                viewModel.setSelectedForRecovery(ids: ids, isSelected: true)
            }
            .disabled(count == 0)

            Button("Remove \(ids.count) from Recovery") {
                viewModel.setSelectedForRecovery(ids: ids, isSelected: false)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = viewModel.thumbnails[item.id] {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(4)
                .overlay(alignment: .bottomTrailing) {
                    if item.kind.isVideoPreviewable {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .padding(8)
                    }
                }
        } else {
            Image(systemName: icon(for: item.kind))
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        }
    }
}

/// SwiftUI's VideoPlayer crashes in a bare SwiftPM executable — its Swift
/// metadata can't resolve AVPlayerView's ObjC superclass at runtime. Hosting
/// AVPlayerView ourselves gives the same transport controls without it.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// EXIF rows. Each appears only when the carved file actually carried the field,
/// since most photos have no GPS and plenty have no lens or exposure data.
private struct ExifRows: View {
    let metadata: ImageMetadata

    var body: some View {
        if let value = metadata.pixelSize {
            MetadataRow(label: "Dimensions", value: value)
        }
        if let value = metadata.captureDate {
            MetadataRow(label: "Captured", value: value)
        }
        if let value = metadata.camera {
            MetadataRow(label: "Camera", value: value)
        }
        if let value = metadata.lens {
            MetadataRow(label: "Lens", value: value)
        }
        if let value = metadata.exposure {
            MetadataRow(label: "Exposure", value: value)
        }
        if let coordinate = metadata.coordinate {
            GridRow {
                Text("Location")
                    .foregroundStyle(.secondary)
                if let url = coordinate.mapsURL {
                    Link(coordinate.label, destination: url)
                        .help("Open in Maps")
                } else {
                    Text(coordinate.label)
                        .textSelection(.enabled)
                }
            }
        }
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

            if viewModel.previewImage != nil {
                Text("Click the image to view it full size")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let item = viewModel.selectedItem {
                VStack(alignment: .leading, spacing: 8) {
                    MetadataRow(label: "Type", value: item.kind.rawValue)
                    MetadataRow(label: "Filename", value: item.filenameLabel)
                    MetadataRow(label: "Size", value: item.sizeLabel)
                    MetadataRow(label: "Offset", value: "0x\(String(item.byteOffset, radix: 16).uppercased())")
                    MetadataRow(label: "Source", value: item.source.displayName)
                    MetadataRow(label: "Selected", value: viewModel.isSelectedForRecovery(item) ? "Yes" : "No")

                    if !viewModel.previewMetadata.isEmpty {
                        Divider()
                        ExifRows(metadata: viewModel.previewMetadata)
                    }
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
            Button {
                viewModel.showFullSizePreview = true
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            }
            .buttonStyle(.plain)
            .help("View full size")
        } else if let player = viewModel.previewPlayer {
            PlayerView(player: player)
                .padding(4)
        } else if let item = viewModel.selectedItem,
                  !item.kind.isPreviewable, !item.kind.isVideoPreviewable {
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
