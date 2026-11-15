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

/// Metric chip above the results: label over a number.
struct StatChip: View {
    let label: String
    let value: String
    var detail: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(tint ?? .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? Color.primary).opacity(tint == nil ? 0.05 : 0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Shown when a scan finishes, until dismissed. Deliberately not a modal: the
/// scan runs for over an hour, so the user is usually away when it ends, and a
/// dialog would have to be clicked away before the results underneath — which
/// already say everything a summary dialog would — could be touched. The
/// counts double as filter buttons, which is the part a modal couldn't do.
struct ScanSummaryBar: View {
    @ObservedObject var viewModel: RecoveryViewModel
    let summary: RecoveryViewModel.ScanSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Finished in \(RecoveryViewModel.elapsedLabel(summary.duration))")
                .font(.callout.weight(.medium))

            Divider().frame(height: 14)

            countButton("\(summary.found.formatted()) found", .all)
            if summary.new > 0 {
                countButton("\(summary.new.formatted()) new", .unrecovered)
            }
            if summary.alreadyRecovered > 0 {
                countButton("\(summary.alreadyRecovered.formatted()) already recovered", .recovered)
            }
            if summary.duplicates > 0 {
                // Not a button: there's no duplicates-only view to jump to.
                Text("\(summary.duplicates.formatted()) duplicates")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Same first 4 KB and length as an earlier result. Select All skips these.")
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func countButton(_ label: String, _ visibility: RecoveredVisibility) -> some View {
        Button(label) { viewModel.recoveredVisibility = visibility }
            .buttonStyle(.link)
            .font(.callout)
            .help("Show only these")
    }
}

struct ResultsView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @Binding var appearanceRaw: String

    private var recoveredCount: Int {
        viewModel.items.count { $0.recoveredURL != nil || $0.previouslyRecovered }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if !viewModel.items.isEmpty {
                HStack(spacing: 10) {
                    StatChip(label: "Found", value: "\(viewModel.items.count)", detail: filteredDetail)
                    StatChip(label: "Selected", value: "\(viewModel.selectedRecoveryIDs.count)", detail: selectedSize)
                    StatChip(
                        label: "Recovered",
                        value: "\(recoveredCount)",
                        detail: viewModel.volumeHistoryCount > 0
                            ? "of \(viewModel.volumeHistoryCount) ever on this drive"
                            : nil,
                        tint: recoveredCount > 0 ? .green : nil
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if let summary = viewModel.scanSummary {
                ScanSummaryBar(viewModel: viewModel, summary: summary)
            }

            if let note = viewModel.scanNote {
                Label(note, systemImage: "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
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
                .padding(.bottom, 10)
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
                    Text(viewModel.items.isEmpty ? "Ready to Scan" : "Recovery Results")
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
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: 230)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))

                    Picker("View", selection: Binding(
                        get: { viewModel.viewMode },
                        set: { viewModel.viewMode = $0 }
                    )) {
                        ForEach(ResultsViewMode.allCases) { mode in
                            Image(systemName: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 86)
                    .labelsHidden()
                    .help("Switch between list and gallery")

                    Menu {
                        Button("Select All Visible") { viewModel.selectAllForRecovery() }
                        Button("Select None") { viewModel.selectNoneForRecovery() }
                    } label: {
                        Label("Selection", systemImage: "checklist")
                    }
                    .help(viewModel.duplicateCount > 0
                          ? "Select All skips \(viewModel.duplicateCount) duplicate\(viewModel.duplicateCount == 1 ? "" : "s")"
                          : "Select or deselect every visible result")
                }

                appearanceMenu
            }

            if !viewModel.items.isEmpty {
                HStack(spacing: 8) {
                    ForEach(RecoveredVisibility.allCases) { visibility in
                        ResultsFilterChip(
                            visibility: visibility,
                            isSelected: viewModel.recoveredVisibility == visibility
                        ) {
                            viewModel.recoveredVisibility = visibility
                        }
                    }

                    Spacer()

                    if let filteredDetail {
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

    private var appearanceMenu: some View {
        Menu {
            ForEach(AppearancePreference.allCases) { preference in
                Button {
                    appearanceRaw = preference.rawValue
                } label: {
                    if preference.rawValue == appearanceRaw {
                        Label(preference.label, systemImage: "checkmark")
                    } else {
                        Text(preference.label)
                    }
                }
            }
        } label: {
            Image(systemName: (AppearancePreference(rawValue: appearanceRaw) ?? .system).systemImage)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 36)
        .help("Appearance")
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
                                StatusBadge(text: recoveredURL.lastPathComponent, tint: .green)
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

                ReviewMarkMenuItems(viewModel: viewModel, ids: ids)
            }
        }
    }

    private var filteredDetail: String? {
        let visible = viewModel.filteredItems.count
        guard visible != viewModel.items.count else { return nil }
        return "\(visible) shown"
    }

    private var selectedSize: String? {
        guard !viewModel.selectedRecoveryIDs.isEmpty else { return nil }
        let total = viewModel.items
            .filter { viewModel.selectedRecoveryIDs.contains($0.id) }
            .reduce(UInt64(0)) { $0 + $1.byteLength }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

struct ResultsFilterChip: View {
    let visibility: RecoveredVisibility
    let isSelected: Bool
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
            Label(visibility.rawValue, systemImage: systemImage)
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
                Text(selectedSize ?? "Mark files above to build your recovery queue")
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
