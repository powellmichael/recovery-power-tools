import AppKit
import AVKit
import SwiftUI

/// Context-menu section for durable review marks, shared by table and gallery.
/// Skipping removes items from the recovery queue; both marks survive rescans.
struct ReviewMarkMenuItems: View {
    @ObservedObject var viewModel: RecoveryViewModel
    let ids: Set<RecoveredItem.ID>

    var body: some View {
        Divider()

        Button("Skip — Don't Recover") {
            viewModel.setReviewMark(.skipped, ids: ids)
        }
        .help("Hide from New; kept out of Select All. Remembered for this drive.")

        Button("Mark as Recovered Elsewhere") {
            viewModel.setReviewMark(.recoveredElsewhere, ids: ids)
        }
        .help("You already have this file from another source. Shows under Recovered.")

        if viewModel.markCount(.skipped, in: ids) > 0 || viewModel.markCount(.recoveredElsewhere, in: ids) > 0 {
            Button("Clear Skip / Elsewhere Marks") {
                viewModel.setReviewMark(nil, ids: ids)
            }
        }
    }
}

/// Small tinted capsule for statuses, replacing bare colored text.
struct StatusBadge: View {
    let text: String
    let tint: Color
    var help: String?

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .help(help ?? text)
    }
}

/// Shown when a scan finishes, until dismissed. Deliberately not a modal: the
/// scan runs for over an hour, so the user is usually away when it ends, and a
/// dialog would have to be clicked away before the results underneath could be
/// touched. Counts live in the filter chips; this band carries what they
/// can't: how long the scan took, duplicates, and what was scanned.
struct ScanSummaryBar: View {
    @ObservedObject var viewModel: RecoveryViewModel
    let summary: RecoveryViewModel.ScanSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Scan finished in \(RecoveryViewModel.elapsedLabel(summary.duration))")
                        .font(.callout.weight(.medium))
                    if summary.duplicates > 0 {
                        Text("· \(summary.duplicates.formatted()) duplicates, left out of Select All")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help("These match an earlier result's first 4 KB and length. They stay in the list and can still be selected one by one.")
                    }
                }
                if summary.unreadableBytes > 0 {
                    Label(
                        "\(ByteCountFormatter.string(fromByteCount: Int64(summary.unreadableBytes), countStyle: .file)) of this drive could not be read. The scan carried on past it; files touching those areas are marked “May be damaged”. A drive with unreadable areas may be failing, so recover what you need soon.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let note = viewModel.scanNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button {
                viewModel.dismissScanSummary()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this summary")
            .accessibilityLabel("Dismiss scan summary")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ResultsView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    /// Returns to the setup step. Nil while a scan is running.
    let scanAgain: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if case .failed(let message) = viewModel.state {
                NoticeBand(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            if let summary = viewModel.scanSummary {
                ScanSummaryBar(viewModel: viewModel, summary: summary)
            }

            if viewModel.items.isEmpty {
                EmptyResultsView()
            } else if viewModel.filteredItems.isEmpty {
                // Results exist but the current view shows none — say why,
                // because an unexplained empty list reads as lost data.
                EmptyFilterExplanation(visibility: viewModel.recoveredVisibility)
            } else {
                HSplitView {
                    Group {
                        if viewModel.viewMode == .gallery {
                            GalleryView(viewModel: viewModel)
                        } else {
                            resultsTable
                        }
                    }
                    // maxWidth .infinity keeps this side flexible, so when the
                    // preview pane closes HSplitView stretches it back to full
                    // width instead of leaving dead space where the pane was.
                    .frame(minWidth: 600, maxWidth: .infinity)

                    if viewModel.isPreviewPaneVisible {
                        PreviewPane(viewModel: viewModel)
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }

            if !viewModel.items.isEmpty {
                Divider()
                RecoveryActionBar(viewModel: viewModel)
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recovery Results")
                        .font(.title2.weight(.semibold))
                    Text(viewModel.sourceLabel ?? "Choose a source")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 20)

                if !viewModel.items.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search filenames", text: Binding(
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
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: 230)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))

                    Picker("View", selection: Binding(
                        get: { viewModel.viewMode },
                        set: { viewModel.setViewMode($0) }
                    )) {
                        ForEach(ResultsViewMode.allCases) { mode in
                            Image(systemName: mode.systemImage)
                                .accessibilityLabel(mode == .gallery ? "Gallery" : "List")
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 86)
                    .labelsHidden()
                    .help("Switch between list and gallery")

                    Menu {
                        Button("Select All Shown") { viewModel.selectAllForRecovery() }
                        Button("Select None") { viewModel.selectNoneForRecovery() }
                    } label: {
                        Label("Selection", systemImage: "checklist")
                    }
                    .help(viewModel.duplicateCount > 0
                          ? "Select All skips \(viewModel.duplicateCount) duplicate\(viewModel.duplicateCount == 1 ? "" : "s")"
                          : "Select or deselect every result shown")
                }

                Menu {
                    if let scanAgain {
                        Button("Scan Again…", action: scanAgain)
                        Button("Choose Another Source") { viewModel.returnToSourceSelection() }
                            .disabled(!viewModel.canReturnToSourceSelection)
                        Divider()
                    }
                    Button("Save Session…") { viewModel.exportManifest() }
                        .disabled(viewModel.items.isEmpty)
                    Button("Open Session…") { viewModel.importManifest() }
                        .disabled(viewModel.isScanActive)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Scan again, change source, or save these results as a session")
            }

            if !viewModel.items.isEmpty {
                HStack(spacing: 8) {
                    ForEach(RecoveredVisibility.allCases) { visibility in
                        ResultsFilterChip(
                            visibility: visibility,
                            count: viewModel.count(for: visibility),
                            isSelected: viewModel.recoveredVisibility == visibility,
                            help: visibility == .recovered && viewModel.volumeHistoryCount > 0
                                ? "\(viewModel.volumeHistoryCount.formatted()) files have ever been recovered from this drive"
                                : nil
                        ) {
                            viewModel.recoveredVisibility = visibility
                        }
                    }

                    Spacer()

                    if let status = viewModel.manifestStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(status)
                    } else if let filteredDetail {
                        Text(filteredDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
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
                            Toggle("Recover \(item.displayName)", isOn: Binding(
                                get: { viewModel.isSelectedForRecovery(item) },
                                set: { viewModel.setSelectedForRecoveryRespectingSelection(item, isSelected: $0) }
                            ))
                            .labelsHidden()
                        }
                        .width(34)

                        TableColumn("Filename", value: \.filenameLabel) { item in
                            HStack(spacing: 6) {
                                Image(systemName: icon(for: item.kind))
                                    .foregroundStyle(.secondary)
                                    .help(item.kind.rawValue)
                                Text(item.filenameLabel)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(item.originalFilename == nil ? .secondary : .primary)
                            }
                        }
                        .width(min: 170, ideal: 240)

                        TableColumn("Type") { item in
                            Text(item.kind.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 90, ideal: 110)

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
                                .accessibilityLabel("Preview \(item.displayName)")
                            }
                        }
                        .width(52)

                        TableColumn("Size", value: \.byteLength) { item in
                            Text(item.sizeLabel)
                                .monospacedDigit()
                        }
                        .width(min: 90, ideal: 110)

                        TableColumn("Status") { item in
                            if let recoveredURL = item.recoveredURL {
                                // Recovered, but with zero-filled gaps or a guessed end.
                                StatusBadge(
                                    text: recoveredURL.lastPathComponent,
                                    tint: item.mayBeDamaged ? .orange : .green,
                                    help: item.mayBeDamaged ? "Recovered. " + RecoveredItem.damagedHelp : nil
                                )
                            } else if let recoveryError = item.recoveryError {
                                StatusBadge(text: recoveryError, tint: .red, help: recoveryError)
                            } else if item.previouslyRecovered {
                                StatusBadge(text: "Recovered previously", tint: .orange)
                            } else if let stale = viewModel.staleReason(for: item) {
                                StatusBadge(
                                    text: stale.rawValue,
                                    tint: .red,
                                    help: "This data changed since the list was saved, so it can no longer be recovered"
                                )
                            } else if item.reviewMark == .skipped {
                                StatusBadge(text: "Skipped", tint: .gray,
                                            help: "Marked to skip — kept out of Select All")
                            } else if item.reviewMark == .recoveredElsewhere {
                                StatusBadge(text: "Recovered elsewhere", tint: .teal,
                                            help: "You already have this file from another source")
                            } else if item.isDuplicate {
                                StatusBadge(
                                    text: "Duplicate",
                                    tint: .purple,
                                    help: "Same first 4 KB and size as an earlier result"
                                )
                            } else if item.mayBeDamaged {
                                StatusBadge(text: "May be damaged", tint: .orange, help: RecoveredItem.damagedHelp)
                            } else {
                                Text("Not recovered yet")
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
                            .accessibilityLabel("Details for \(item.displayName)")
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

                ReviewMarkMenuItems(viewModel: viewModel, ids: ids)
            }
        }
    }

    private var filteredDetail: String? {
        let visible = viewModel.filteredItems.count
        guard visible != viewModel.items.count else { return nil }
        return "\(visible) shown"
    }
}

struct ResultsFilterChip: View {
    let visibility: RecoveredVisibility
    let count: Int
    let isSelected: Bool
    var help: String? = nil
    let action: () -> Void

    private var systemImage: String {
        switch visibility {
        case .all: "square.grid.2x2"
        case .unrecovered: "sparkles"
        case .marked: "checkmark.square"
        case .recovered: "checkmark.circle"
        }
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(visibility.rawValue)
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            } icon: {
                Image(systemName: systemImage)
            }
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background(
                    isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .accessibilityLabel("\(visibility.rawValue), \(count.formatted()) files")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Persistent recovery queue: selection context, output format, and the one
/// primary action stay visible while the user reviews a long list or gallery.
struct RecoveryActionBar: View {
    @ObservedObject var viewModel: RecoveryViewModel

    private var selectedCount: Int { viewModel.selectedRecoveryIDs.count }

    private var selectedSize: String? {
        guard selectedCount > 0 else { return nil }
        let bytes = viewModel.items.reduce(UInt64(0)) { total, item in
            viewModel.selectedRecoveryIDs.contains(item.id) ? total + item.byteLength : total
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var selectionLabel: String {
        guard selectedCount > 0 else { return "No files selected" }
        return "\(selectedCount.formatted()) file\(selectedCount == 1 ? "" : "s") selected"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: selectedCount > 0 ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(selectedCount > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                Text(selectionLabel)
                    .font(.callout.weight(.semibold))
                Text(selectedSize ?? "Tick the files you want, then recover them to another drive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if viewModel.saveAsZip {
                TextField("ZIP name (optional)", text: Binding(
                    get: { viewModel.zipFileName },
                    set: { viewModel.zipFileName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            }

            Menu {
                Button {
                    viewModel.saveAsZip = false
                } label: {
                    Label("Recover as Files", systemImage: viewModel.saveAsZip ? "folder" : "checkmark")
                }
                Button {
                    viewModel.saveAsZip = true
                } label: {
                    Label("Create ZIP Archive", systemImage: viewModel.saveAsZip ? "checkmark" : "archivebox")
                }
            } label: {
                Label(viewModel.saveAsZip ? "ZIP Archive" : "Files", systemImage: viewModel.saveAsZip ? "archivebox" : "folder")
            }
            .help("Choose whether to recover individual files or one ZIP archive")

            if viewModel.state == .recovering {
                ProgressView()
                    .controlSize(.small)
                Text("Recovering…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.recoverSelected()
            } label: {
                Label(
                    selectedCount == 0
                        ? "Recover Selected…"
                        : "Recover \(selectedCount.formatted()) File\(selectedCount == 1 ? "" : "s")…",
                    systemImage: "arrow.down.doc.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canRecover)
            .help("Choose a destination and recover the selected files")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}


struct GalleryView: View {
    @ObservedObject var viewModel: RecoveryViewModel

    // Adaptive: uses window width instead of stretching a fixed 4 columns.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.filteredItems) { item in
                    GalleryCell(viewModel: viewModel, item: item)
                        .onAppear { viewModel.requestThumbnail(for: item) }
                }
            }
            .padding(12)
        }
    }
}

struct GalleryCell: View {
    @ObservedObject var viewModel: RecoveryViewModel
    let item: RecoveredItem

    private var isSelected: Bool { viewModel.tableSelection.contains(item.id) }

    var body: some View {
        VStack(spacing: 6) {
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
                        .frame(height: 124)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.originalFilename == nil ? .secondary : .primary)

            HStack(spacing: 5) {
                Text(item.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if item.recoveredURL != nil {
                    StatusBadge(text: "Recovered", tint: .green)
                } else if item.previouslyRecovered {
                    StatusBadge(text: "Recovered previously", tint: .orange)
                } else if item.reviewMark == .skipped {
                    StatusBadge(text: "Skipped", tint: .gray,
                                help: "Marked to skip — kept out of Select All")
                } else if item.reviewMark == .recoveredElsewhere {
                    StatusBadge(text: "Recovered elsewhere", tint: .teal,
                                help: "You already have this file from another source")
                } else if item.isDuplicate {
                    StatusBadge(text: "Duplicate", tint: .purple,
                                help: "Same first 4 KB and size as an earlier result")
                } else if item.mayBeDamaged {
                    StatusBadge(text: "May be damaged", tint: .orange, help: RecoveredItem.damagedHelp)
                }
            }
        }
        .padding(8)
        .background(
            isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.4)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 2 : 1)
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

            ReviewMarkMenuItems(viewModel: viewModel, ids: ids)
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
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }
}

/// SwiftUI's VideoPlayer crashes in a bare SwiftPM executable — its Swift
/// metadata can't resolve AVPlayerView's ObjC superclass at runtime. Hosting
/// AVPlayerView ourselves gives the same transport controls without it.
struct PlayerView: NSViewRepresentable {
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
struct ExifRows: View {
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

struct PreviewPane: View {
    @ObservedObject var viewModel: RecoveryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)

            previewContent
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

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

struct MetadataRow: View {
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

/// Shown when the scan found items but the active visibility filter hides all
/// of them. The Recovered case matters most: recovered files reappear only
/// when a scan re-finds them, which depends on the media types selected — an
/// Images-only scan will never re-find recovered videos.
struct EmptyFilterExplanation: View {
    let visibility: RecoveredVisibility

    private var message: (icon: String, title: String, detail: String) {
        switch visibility {
        case .all:
            ("line.3.horizontal.decrease.circle", "No results match",
             "The filename filter hides every result.")
        case .unrecovered:
            ("checkmark.circle", "Nothing new here",
             "Every result is recovered, skipped, or marked as recovered elsewhere.")
        case .marked:
            ("checklist.unchecked", "Nothing marked for recovery",
             "Tick files to queue them, then review the queue here before recovering.")
        case .recovered:
            ("clock.arrow.circlepath", "No recovered files in this scan",
             "Recovered files appear here only when a scan finds them again — "
             + "and a scan only looks for the media types selected in the sidebar. "
             + "Files recovered under other types (for example videos, during an "
             + "images-only scan) stay in the history and reappear when their "
             + "types are selected.")
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: message.icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(message.title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(message.detail)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyResultsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("No media found")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Choose a drive, pick the media types to look for, and scan.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What a finished recovery reports. It used to be an alert whose only
/// question was whether to untick the files; the things a person actually
/// wants next are to see the files and to know if any failed.
struct RecoveryCompleteSheet: View {
    @ObservedObject var viewModel: RecoveryViewModel

    private var recovered: Int { viewModel.justRecoveredCount }
    private var failed: Int { viewModel.recoveryFailureCount }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(failed > 0 ? .orange : .green)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Recovered \(recovered.formatted()) file\(recovered == 1 ? "" : "s")")
                    .font(.title2.weight(.semibold))
                if let destination = viewModel.destinationURL {
                    Text("Saved to \(destination.path)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                if failed > 0 {
                    Text("\(failed.formatted()) file\(failed == 1 ? "" : "s") could not be recovered. Each one shows its reason in the Status column.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button("Show in Finder") {
                    viewModel.revealRecoveredFiles()
                }
                Button("Untick Recovered Files") {
                    viewModel.uncheckRecoveredFiles()
                    viewModel.showRecoveryCompletePrompt = false
                }
                .help("Clear the ticks on the files just recovered, so they aren't recovered twice")
                Button("Done") {
                    viewModel.showRecoveryCompletePrompt = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 460)
    }
}
