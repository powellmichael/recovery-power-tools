import AppKit
import Foundation
import ImageIO
import SwiftUI

@MainActor
final class RecoveryViewModel: ObservableObject {
    @Published var target: ScanTarget?
    @Published var destinationURL: URL?
    @Published var selectedKinds: Set<MediaKind> = [.jpeg]
    @Published var items: [RecoveredItem] = []
    @Published var progress = ScanProgress()
    @Published var state: ScanState = .idle
    @Published var selectedItemID: RecoveredItem.ID?
    @Published var selectedRecoveryIDs: Set<RecoveredItem.ID> = []
    @Published var previewImage: NSImage?
    @Published var previewFileURL: URL?
    @Published var previewError: String?
    @Published var externalDevices: [ExternalDevice] = []
    @Published var scanNote: String?
    @Published var filenameFilter = ""
    @Published var sortOrder: [KeyPathComparator<RecoveredItem>] = []
    @Published var isPreviewPaneVisible = false
    @Published var showFullSizePreview = false
    @Published var saveAsZip = false
    @Published var zipFileName = ""
    @Published var recoveredVisibility: RecoveredVisibility = .all
    @Published var showClearFilterPrompt = false
    @Published var viewMode: ResultsViewMode = .list
    @Published private(set) var thumbnails: [RecoveredItem.ID: NSImage] = [:]
    private var thumbnailsRequested: Set<RecoveredItem.ID> = []

    var filteredItems: [RecoveredItem] {
        var visible = items
        switch recoveredVisibility {
        case .all:
            break
        case .unrecovered:
            visible = visible.filter { !$0.previouslyRecovered && $0.recoveredURL == nil }
        case .recovered:
            visible = visible.filter { $0.previouslyRecovered || $0.recoveredURL != nil }
        }
        if !filenameFilter.isEmpty {
            visible = visible.filter { $0.displayName.localizedCaseInsensitiveContains(filenameFilter) }
        }
        if !sortOrder.isEmpty {
            visible.sort(using: sortOrder)
        }
        return visible
    }

    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pendingItems: [RecoveredItem] = []
    private var flushScheduled = false
    private var pauseGate: PauseGate?
    private var recoveryLog = RecoveryLog.load()
    private var currentVolumeID: UInt64 = 0

    /// Stable identity for a found file across scans: volume serial (when the
    /// filesystem was recognized) plus location. ponytail: unrecognized
    /// filesystems fall back to the source name, which is weaker.
    private func logKey(for item: RecoveredItem) -> String {
        let volume = currentVolumeID != 0 ? "v\(currentVolumeID)" : "n\(item.source.displayName)"
        return "\(volume):\(item.byteOffset):\(item.byteLength)"
    }
    private let scanner = RecoveryScanner()

    init() {
        // SwiftUI's Table focus and bare-key shortcuts are both unreliable on
        // macOS; an AppKit event monitor always sees arrow keys.
        // ponytail: monitor lives for the app's lifetime, never removed —
        // there is exactly one view model per app.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.items.isEmpty,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else {
                return event
            }
            switch event.keyCode {
            case 125: // down arrow
                self.moveSelection(1)
                return nil
            case 126: // up arrow
                self.moveSelection(-1)
                return nil
            default:
                return event
            }
        }
    }

    var isScanActive: Bool {
        state == .scanning || state == .paused
    }

    var canScan: Bool {
        target != nil && !isScanActive && state != .recovering && !selectedKinds.isEmpty
    }

    var canRecover: Bool {
        destinationURL != nil && !selectedRecoveryIDs.isEmpty && !isScanActive && state != .recovering
    }

    /// Warns when the user picked a folder on an external drive: folder scans
    /// inspect live files only, so deleted files will never appear.
    var sourceWarning: String? {
        guard case .path(let url) = target,
              let device = DeviceDiscovery.externalDevice(containing: url, in: externalDevices) else { return nil }
        return "This folder is on \(device.displayName). Folder scans only look inside existing files — deleted files will NOT be found. Use Choose Drive and pick that device to scan its free space for deleted files."
    }

    var sourceLabel: String? {
        switch target {
        case .path(let url): url.lastPathComponent
        case .device(let device): device.displayName
        case nil: nil
        }
    }

    var selectedItem: RecoveredItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose Source"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            setTarget(.path(url))
        }
    }

    func chooseDevice(_ device: ExternalDevice) {
        setTarget(.device(device))
    }

    func refreshDevices() {
        Task { [weak self] in
            let devices = await Self.listDevices()
            self?.externalDevices = devices
        }
    }

    private nonisolated static func listDevices() async -> [ExternalDevice] {
        DeviceDiscovery.externalDevices()
    }

    private func setTarget(_ newTarget: ScanTarget) {
        target = newTarget
        items = []
        selectedRecoveryIDs = []
        selectedItemID = nil
        previewImage = nil
        previewFileURL = nil
        previewError = nil
        progress = ScanProgress()
        scanNote = nil
        clearThumbnails()
        state = .idle
    }

    private func clearThumbnails() {
        thumbnails = [:]
        thumbnailsRequested = []
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recovery Destination"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK {
            destinationURL = panel.url
        }
    }

    func toggleKind(_ kind: MediaKind) {
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
    }

    func allSelected(in category: MediaCategory) -> Bool {
        category.kinds.allSatisfy(selectedKinds.contains)
    }

    func someSelected(in category: MediaCategory) -> Bool {
        category.kinds.contains(where: selectedKinds.contains)
    }

    func setKinds(in category: MediaCategory, on: Bool) {
        if on {
            selectedKinds.formUnion(category.kinds)
        } else {
            selectedKinds.subtract(category.kinds)
        }
    }

    /// Scan button entry point: if a filename filter is active it would hide
    /// some new results, so ask whether to clear it first.
    func scanButtonPressed() {
        if !filenameFilter.isEmpty {
            showClearFilterPrompt = true
        } else {
            startScan()
        }
    }

    func confirmScan(clearFilter: Bool) {
        showClearFilterPrompt = false
        if clearFilter {
            filenameFilter = ""
        }
        startScan()
    }

    func startScan() {
        guard let target else { return }
        scanTask?.cancel()
        items = []
        selectedRecoveryIDs = []
        selectedItemID = nil
        previewImage = nil
        previewFileURL = nil
        previewError = nil
        progress = ScanProgress()
        scanNote = nil
        clearThumbnails()
        state = .scanning

        let scanner = scanner
        let kinds = selectedKinds
        let gate = PauseGate()
        pauseGate = gate

        scanTask = Task { [weak self] in
            do {
                // makePlan runs off the main actor; for devices it blocks on the
                // macOS authorization prompt.
                let plan = try await scanner.makePlan(for: target)
                await MainActor.run {
                    self?.scanNote = plan.note
                    self?.currentVolumeID = plan.volumeID
                }

                let found = try await scanner.scan(
                    plan: plan,
                    selectedKinds: kinds,
                    pauseGate: gate,
                    progress: { newProgress in
                        await MainActor.run { self?.progress = newProgress }
                    },
                    itemFound: { item in
                        await MainActor.run {
                            self?.enqueueFoundItem(item)
                        }
                    }
                )

                await MainActor.run {
                    guard let self else { return }
                    self.flushPendingItems()
                    let existingIDs = Set(self.items.map(\.id))
                    let missing = found.filter { !existingIDs.contains($0.id) }.map { self.markedIfPreviouslyRecovered($0) }
                    self.items.append(contentsOf: missing)
                    self.state = .finished
                }
            } catch is CancellationError {
                await MainActor.run { self?.state = .idle }
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        pauseGate = nil
        flushPendingItems()
        state = .idle
    }

    func togglePause() {
        switch state {
        case .scanning:
            pauseGate?.setPaused(true)
            state = .paused
        case .paused:
            pauseGate?.setPaused(false)
            state = .scanning
        default:
            break
        }
    }

    /// Found items are buffered and flushed a few times a second — appending
    /// them one at a time rebuilds the table constantly, which eats clicks
    /// and key presses.
    private func enqueueFoundItem(_ item: RecoveredItem) {
        pendingItems.append(item)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.flushScheduled = false
            self?.flushPendingItems()
        }
    }

    /// Found items are NOT auto-selected for recovery: the user picks
    /// explicitly (or uses Select All on a filtered list).
    private func markedIfPreviouslyRecovered(_ item: RecoveredItem) -> RecoveredItem {
        var item = item
        item.previouslyRecovered = recoveryLog.contains(logKey(for: item))
        return item
    }

    private func flushPendingItems() {
        guard !pendingItems.isEmpty else { return }
        items.append(contentsOf: pendingItems.map { markedIfPreviouslyRecovered($0) })
        pendingItems = []
        if selectedItemID == nil, let first = items.first {
            selectedItemID = first.id
            preparePreview(for: first)
        }
    }

    func moveSelection(_ delta: Int) {
        let visible = filteredItems
        guard !visible.isEmpty else { return }
        let currentIndex = visible.firstIndex { $0.id == selectedItemID } ?? (delta > 0 ? -1 : visible.count)
        let newIndex = min(max(currentIndex + delta, 0), visible.count - 1)
        selectItem(visible[newIndex].id)
    }

    /// Gallery cells ask for thumbnails as they scroll into view. Each item is
    /// rendered once; huge files are skipped rather than decoded.
    /// ponytail: unbounded cache, no eviction — add an LRU if a scan with tens
    /// of thousands of images starts hurting memory.
    func requestThumbnail(for item: RecoveredItem) {
        guard item.kind.isPreviewable,
              item.byteLength <= 64 * 1024 * 1024,
              thumbnailsRequested.insert(item.id).inserted else { return }

        let scanner = scanner
        let itemID = item.id
        Task.detached(priority: .utility) { [weak self] in
            let url = Self.previewURL(for: item)
            defer { try? FileManager.default.removeItem(at: url) }
            try? scanner.write(item, to: url)
            // NSImage isn't Sendable, so hand back PNG bytes and build the
            // image on the main actor.
            guard let data = Self.thumbnailData(at: url, maxPixel: 320) else { return }
            await self?.setThumbnail(data, for: itemID)
        }
    }

    private func setThumbnail(_ data: Data, for itemID: RecoveredItem.ID) {
        guard let image = NSImage(data: data) else { return }
        thumbnails[itemID] = image
    }

    private nonisolated static func thumbnailData(at url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Preview-column click: select the row and make sure the pane is shown.
    func showDetails(for item: RecoveredItem) {
        selectItem(item.id)
        isPreviewPaneVisible = true
    }

    /// Details-column click: toggles the pane when re-clicking the selected
    /// row, otherwise selects the row and shows the pane.
    func toggleDetails(for item: RecoveredItem) {
        if isPreviewPaneVisible && selectedItemID == item.id {
            isPreviewPaneVisible = false
        } else {
            selectItem(item.id)
            isPreviewPaneVisible = true
        }
    }

    func selectItem(_ itemID: RecoveredItem.ID?) {
        selectedItemID = itemID
        guard let item = selectedItem else {
            previewImage = nil
            previewFileURL = nil
            previewError = nil
            return
        }
        preparePreview(for: item)
    }

    func isSelectedForRecovery(_ item: RecoveredItem) -> Bool {
        selectedRecoveryIDs.contains(item.id)
    }

    func setSelectedForRecovery(_ item: RecoveredItem, isSelected: Bool) {
        if isSelected {
            selectedRecoveryIDs.insert(item.id)
        } else {
            selectedRecoveryIDs.remove(item.id)
        }
    }

    /// Selects the visible (filtered) items, so a filename filter can scope
    /// exactly what gets recovered.
    func selectAllForRecovery() {
        selectedRecoveryIDs.formUnion(filteredItems.map(\.id))
    }

    func selectNoneForRecovery() {
        selectedRecoveryIDs = []
    }

    func recoverSelected() {
        guard let destinationURL else { return }
        if case .device(let device) = target,
           DeviceDiscovery.destination(destinationURL, isOnSameDiskAs: device) {
            state = .failed(RecoveryError.destinationOnSourceDisk.localizedDescription)
            return
        }
        state = .recovering

        let scanner = scanner
        let selected = items.filter { selectedRecoveryIDs.contains($0.id) }
        let zipName: String? = saveAsZip ? Self.sanitizedZipName(zipFileName) : nil
        let hadCustomZipName = saveAsZip && !zipFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task.detached { [weak self] in
            // Zip mode recovers into a temp folder first, then archives it.
            let recoveryDir: URL
            if zipName != nil {
                recoveryDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FileRecoveryZip-\(UUID().uuidString)", isDirectory: true)
            } else {
                recoveryDir = destinationURL
            }

            var outcomes: [(id: RecoveredItem.ID, url: URL?, error: String?)] = []
            for item in selected {
                if Task.isCancelled { break }
                do {
                    outcomes.append((item.id, try scanner.recover(item, to: recoveryDir), nil))
                } catch {
                    outcomes.append((item.id, nil, error.localizedDescription))
                }
            }

            if let zipName {
                defer { try? FileManager.default.removeItem(at: recoveryDir) }
                do {
                    let zipURL = try Self.zip(directory: recoveryDir, to: destinationURL, name: zipName)
                    outcomes = outcomes.map { ($0.id, $0.url == nil ? nil : zipURL, $0.error) }
                } catch {
                    let message = error.localizedDescription
                    outcomes = outcomes.map { ($0.id, nil, $0.error ?? message) }
                }
            }
            await self?.applyRecoveryOutcomes(outcomes, clearZipNameOnSuccess: hadCustomZipName)
        }
    }

    private nonisolated static func sanitizedZipName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if name.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            name = "recovered-\(stamp)"
        }
        return name.lowercased().hasSuffix(".zip") ? name : "\(name).zip"
    }

    /// Archives the folder's contents with the system's ditto tool.
    private nonisolated static func zip(directory: URL, to destination: URL, name: String) throws -> URL {
        var zipURL = destination.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: zipURL.path) {
            let base = (name as NSString).deletingPathExtension
            zipURL = destination.appendingPathComponent("\(base)-\(counter).zip")
            counter += 1
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", directory.path, zipURL.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecoveryError.cannotCreateOutput(zipURL.path)
        }
        return zipURL
    }

    private func applyRecoveryOutcomes(_ outcomes: [(id: RecoveredItem.ID, url: URL?, error: String?)], clearZipNameOnSuccess: Bool = false) {
        var recordedAny = false
        for outcome in outcomes {
            guard let index = items.firstIndex(where: { $0.id == outcome.id }) else { continue }
            if let url = outcome.url {
                items[index].recoveredURL = url
                items[index].recoveryError = nil
                recoveryLog.record(logKey(for: items[index]))
                recordedAny = true
            } else {
                items[index].recoveryError = outcome.error
            }
        }
        if recordedAny {
            recoveryLog.save()
            if clearZipNameOnSuccess {
                zipFileName = ""
            }
        }
        state = .finished
    }

    private func preparePreview(for item: RecoveredItem) {
        previewTask?.cancel()
        previewImage = nil
        previewFileURL = nil
        previewError = nil

        guard item.kind.isPreviewable else { return }

        let scanner = scanner
        previewTask = Task {
            do {
                let outputURL = Self.previewURL(for: item)
                try scanner.write(item, to: outputURL)
                try Task.checkCancellation()

                let image = NSImage(contentsOf: outputURL)

                await MainActor.run {
                    previewFileURL = outputURL
                    previewImage = image
                    previewError = image == nil ? "Preview unavailable" : nil
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    previewError = error.localizedDescription
                }
            }
        }
    }

    private nonisolated static func previewURL(for item: RecoveredItem) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileRecoveryPreviews", isDirectory: true)
            .appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
    }
}
