import AppKit
import AVKit
import SwiftUI

/// User-facing appearance preference. System follows the Mac's setting by
/// mapping to a nil preferredColorScheme.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = RecoveryViewModel()
    @AppStorage("appearance") private var appearanceRaw = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 270, ideal: 310)
        } detail: {
            ResultsView(viewModel: viewModel, appearanceRaw: $appearanceRaw)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showFullSizePreview && viewModel.previewImage != nil },
            set: { viewModel.showFullSizePreview = $0 }
        )) {
            FullSizePreview(viewModel: viewModel)
        }
        .preferredColorScheme(appearance.colorScheme)
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
            // Adapts to appearance; the old hardcoded black wash was wrong in
            // light mode.
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 600, idealWidth: 1000, minHeight: 400, idealHeight: 720)
    }
}

/// A quiet titled card, the sidebar's basic unit.
private struct SidebarCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
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
                VStack(alignment: .leading, spacing: 12) {
                    SidebarCard(title: "Source") {
                        PathRow(
                            label: viewModel.sourceLabel,
                            placeholder: "No source selected",
                            systemImage: "externaldrive"
                        )
                        HStack(spacing: 6) {
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
                                Label("Drive", systemImage: "externaldrive")
                                    .frame(maxWidth: .infinity)
                            }
                            .help("Choose an external drive to scan")

                            Button {
                                viewModel.chooseSource()
                            } label: {
                                Label("File / Folder", systemImage: "folder.badge.gearshape")
                                    .frame(maxWidth: .infinity)
                            }
                            .help("Choose a file or folder to scan")
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

                    SidebarCard(title: "Destination") {
                        PathRow(
                            label: viewModel.destinationURL?.lastPathComponent,
                            placeholder: "No destination selected",
                            systemImage: "folder"
                        )
                        Button {
                            viewModel.chooseDestination()
                        } label: {
                            Label("Choose Folder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    SidebarCard(title: "Media") {
                        MediaFilterList(viewModel: viewModel)
                        if viewModel.selectedKinds.isEmpty {
                            Text("Nothing selected — the scan will look for every type.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
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
                        .controlSize(.large)
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
                            HStack(spacing: 6) {
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
                    }

                    SidebarCard(title: "File List") {
                        HStack(spacing: 6) {
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
                        }

                        if let status = viewModel.manifestStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            StatusBlock(viewModel: viewModel)
                .padding(14)
                .background(.quaternary.opacity(0.35))
        }
        .onAppear {
            viewModel.refreshDevices()
        }
    }
}

private struct PathRow: View {
    let label: String?
    let placeholder: String
    var systemImage = "checkmark.circle"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: label == nil ? "minus.circle" : systemImage)
                .foregroundStyle(label == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Text(label ?? placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(label == nil ? .secondary : .primary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusBlock: View {
    @ObservedObject var viewModel: RecoveryViewModel

    private var stateLabel: (String, String) {
        switch viewModel.state {
        case .idle: ("Ready", "circle")
        case .scanning: ("Scanning", "waveform.path.ecg")
        case .paused: ("Paused", "pause.circle")
        case .recovering: ("Recovering", "tray.and.arrow.down")
        case .finished: ("Finished", "checkmark.circle")
        case .failed: ("Needs Attention", "exclamationmark.triangle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(stateLabel.0, systemImage: stateLabel.1)
                    .font(.callout.weight(.medium))
                Spacer()
                if let percent = viewModel.progress.percentLabel, viewModel.progress.totalBytes > 0 {
                    Text(percent)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .help("Share of the scanned area read so far. Files are found unevenly, so this is an estimate.")
                }
            }

            ProgressView(value: viewModel.progress.fraction)
                .opacity(viewModel.isScanActive ? 1 : 0.35)

            if let bytes = viewModel.progress.byteLabel, viewModel.progress.totalBytes > 0 {
                Text(bytes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(viewModel.items.count) found · \(viewModel.selectedRecoveryIDs.count) selected")
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

/// Context-menu section for durable review marks, shared by table and gallery.
/// Skipping removes items from the recovery queue; both marks survive rescans.
private struct ReviewMarkMenuItems: View {
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
private struct StatusBadge: View {
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
private struct StatChip: View {
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

private struct ResultsView: View {
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
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Recoverable Media")
                .font(.headline)
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
                .frame(maxWidth: 200)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: 220)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

                Menu {
                    Button("Select All") { viewModel.selectAllForRecovery() }
                    Button("Select None") { viewModel.selectNoneForRecovery() }
                } label: {
                    Image(systemName: "checklist")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 44)
                .help(viewModel.duplicateCount > 0
                      ? "Select All picks everything except \(viewModel.duplicateCount) duplicate\(viewModel.duplicateCount == 1 ? "" : "s")"
                      : "Select or deselect every visible result")
            }

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
            .frame(width: 40)
            .help("Appearance")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                // Without an explicit leading alignment each row centres itself,
                // so "MP4 / MOV" and "AVI" start at different x positions and
                // the list reads as a staircase.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(category.kinds) { kind in
                        Toggle(kind.rawValue, isOn: Binding(
                            get: { viewModel.selectedKinds.contains(kind) },
                            set: { _ in viewModel.toggleKind(kind) }
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.leading, 2)
            } label: {
                Toggle(isOn: Binding(
                    get: { viewModel.allSelected(in: category) },
                    set: { viewModel.setKinds(in: category, on: $0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: categoryIcon(category))
                            .foregroundStyle(.secondary)
                        Text(category.rawValue)
                        if viewModel.someSelected(in: category), !viewModel.allSelected(in: category) {
                            Text("\(category.kinds.filter(viewModel.selectedKinds.contains).count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    private func categoryIcon(_ category: MediaCategory) -> String {
        switch category {
        case .images: "photo"
        case .video: "video"
        case .archives: "archivebox"
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

private struct GalleryCell: View {
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

/// Shown when the scan found items but the active visibility filter hides all
/// of them. The Recovered case matters most: recovered files reappear only
/// when a scan re-finds them, which depends on the media types selected — an
/// Images-only scan will never re-find recovered videos.
private struct EmptyFilterExplanation: View {
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

private struct EmptyResultsView: View {
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
