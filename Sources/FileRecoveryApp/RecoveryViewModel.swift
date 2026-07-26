import AVKit
import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecoveryViewModel: ObservableObject {
    @Published var target: ScanTarget?
    @Published var destinationURL: URL?
    /// Empty means "every type" at scan time — see effectiveKinds. Nothing is
    /// checked by default so a scan defaults to finding everything.
    @Published var selectedKinds: Set<MediaKind> = []
    @Published var items: [RecoveredItem] = [] { didSet { filteredCache = nil } }
    @Published var progress = ScanProgress()
    @Published var state: ScanState = .idle
    @Published var selectedItemID: RecoveredItem.ID?
    /// Highlighted rows. Shift- and command-click build this set; the preview
    /// pane follows it only when exactly one row is selected.
    @Published var tableSelection: Set<RecoveredItem.ID> = []
    /// Where a shift-click range starts. Set by a plain or command click.
    private var selectionAnchorID: RecoveredItem.ID?
    /// Only the "Marked" view filters on this, so ticking a checkbox in any
    /// other view must not throw the filtered list away — that happens once per
    /// click while bulk-selecting.
    @Published var selectedRecoveryIDs: Set<RecoveredItem.ID> = [] {
        didSet { if recoveredVisibility == .marked { filteredCache = nil } }
    }
    @Published var previewImage: NSImage?
    @Published var previewPlayer: AVPlayer?
    @Published var previewMetadata = ImageMetadata()
    @Published var previewFileURL: URL?
    @Published var previewError: String?
    @Published var externalDevices: [ExternalDevice] = []
    @Published var scanNote: String?
    @Published var filenameFilter = "" { didSet { filteredCache = nil } }
    @Published var sortOrder: [KeyPathComparator<RecoveredItem>] = [] { didSet { filteredCache = nil } }
    @Published var isPreviewPaneVisible = false
    @Published var showFullSizePreview = false
    @Published var saveAsZip = false
    @Published var zipFileName = ""
    @Published var recoveredVisibility: RecoveredVisibility = .all { didSet { filteredCache = nil } }
    @Published var showClearFilterPrompt = false
    /// Fast scan: quicker but skips brute-force recovery of damaged files.
    @Published var fastScan = false
    /// Recovery-complete prompt, offering to uncheck the files just written.
    @Published var showRecoveryCompletePrompt = false
    @Published private(set) var recoveryFailureCount = 0
    private var justRecoveredIDs: [RecoveredItem.ID] = []

    /// How many files the just-finished recovery wrote — drives the prompt text.
    var justRecoveredCount: Int { justRecoveredIDs.count }
    @Published var viewMode: ResultsViewMode = .list
    @Published private(set) var thumbnails: [RecoveredItem.ID: NSImage] = [:]
    private var thumbnailsRequested: Set<RecoveredItem.ID> = []

    /// Cleared by the didSet on every input below. Nil means "recompute".
    private var filteredCache: [RecoveredItem]?

    /// SwiftUI reads this several times per render pass, and so do the arrow
    /// keys, shift-click and Select All. Recomputing meant re-filtering and
    /// re-sorting the whole result set each time, so the cached value is what
    /// keeps a large scan navigable.
    var filteredItems: [RecoveredItem] {
        if let filteredCache { return filteredCache }
        let computed = computeFilteredItems()
        filteredCache = computed
        return computed
    }

    private func computeFilteredItems() -> [RecoveredItem] {
        var visible = items
        switch recoveredVisibility {
        case .all:
            break
        case .unrecovered:
            // "New" means still needing a decision: not recovered by the app,
            // not marked skipped or recovered-elsewhere.
            visible = visible.filter {
                !$0.previouslyRecovered && $0.recoveredURL == nil && $0.reviewMark == nil
            }
        case .marked:
            visible = visible.filter { selectedRecoveryIDs.contains($0.id) }
        case .recovered:
            // Recovered-elsewhere counts: from the user's point of view the
            // file is recovered, just not by this tool.
            visible = visible.filter {
                $0.previouslyRecovered || $0.recoveredURL != nil || $0.reviewMark == .recoveredElsewhere
            }
        }
        if !filenameFilter.isEmpty {
            visible = visible.filter { $0.displayName.localizedCaseInsensitiveContains(filenameFilter) }
        }
        if !sortOrder.isEmpty {
            visible.sort(using: sortOrder)
        }
        return visible
    }

    /// What a finished scan found. Deliberately a frozen snapshot rather than
    /// live counts: it describes the scan that just completed, and recomputing
    /// four passes over 200k items on every render is exactly the cost the
    /// filtered-list cache exists to avoid.
    struct ScanSummary: Equatable, Sendable {
        var duration: TimeInterval
        var found: Int
        var duplicates: Int
        var alreadyRecovered: Int
        var new: Int
    }

    /// Non-nil from the end of a scan until dismissed or the next scan starts.
    @Published var scanSummary: ScanSummary?

    static func summarize(_ items: [RecoveredItem], duration: TimeInterval) -> ScanSummary {
        var duplicates = 0, alreadyRecovered = 0, new = 0
        for item in items {
            if item.isDuplicate { duplicates += 1 }
            // Matches the Recovered view: recovered-elsewhere counts, because
            // from the user's point of view the file is already saved.
            if item.previouslyRecovered || item.recoveredURL != nil || item.reviewMark == .recoveredElsewhere {
                alreadyRecovered += 1
            } else if item.reviewMark == nil {
                new += 1
            }
        }
        return ScanSummary(
            duration: duration,
            found: items.count,
            duplicates: duplicates,
            alreadyRecovered: alreadyRecovered,
            new: new
        )
    }

    func dismissScanSummary() {
        scanSummary = nil
    }

    /// A scan runs for an hour or more, so the user is rarely watching when it
    /// ends. requestUserAttention bounces the dock icon until the app is
    /// focused. A Notification Centre banner would be better, but that needs a
    /// bundle identifier and this ships as a bare SwiftPM executable.
    private func announceCompletion() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.criticalRequest)
    }

    /// When the running segment of the current scan started, or nil when the
    /// clock is stopped. Paused time is deliberately excluded — "how long has
    /// this been running" shouldn't keep climbing while the user has it
    /// deliberately halted, and a pause can last hours.
    @Published private(set) var scanStartedAt: Date?
    /// Time banked from earlier segments of the same scan, before each pause.
    private var bankedScanTime: TimeInterval = 0

    var elapsedScanTime: TimeInterval {
        bankedScanTime + (scanStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Nil until a scan has run, so the UI shows nothing on a fresh launch.
    /// Survives completion on purpose: "that took 3h 12m" is worth keeping.
    var elapsedScanLabel: String? {
        guard scanStartedAt != nil || bankedScanTime > 0 else { return nil }
        return Self.elapsedLabel(elapsedScanTime)
    }

    /// Compact and fixed-width-ish so a ticking clock doesn't jitter the layout.
    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return "\(secs)s"
    }

    /// Power-management assertion held while a scan is actually running.
    ///
    /// Without it macOS App Nap is free to throttle the process once the app
    /// stops being frontmost: it lowers CPU priority, coalesces timers and
    /// demotes disk I/O to a background tier. Locking the screen during a real
    /// 842 GB scan roughly halved throughput for the locked hour. A scan that
    /// runs unattended for hours is the exact case App Nap should not touch.
    ///
    /// `.userInitiated` already implies `.idleSystemSleepDisabled`, so this
    /// also stops the system idle-sleeping mid-scan. Display sleep is left
    /// alone — the screen going dark is fine and saves power.
    private var scanActivity: NSObjectProtocol?

    /// Test seam: whether the assertion is currently held.
    var isHoldingScanActivity: Bool { scanActivity != nil }

    /// Internal rather than private so tests can drive the clock without
    /// running a real scan against a real device.
    ///
    /// The power assertion is tied to the clock deliberately: the clock runs
    /// exactly when the scan does (it stops on pause and at every exit path),
    /// so binding them here means the two can never drift out of step.
    func startScanClock(resetTotal: Bool) {
        if resetTotal { bankedScanTime = 0 }
        scanStartedAt = Date()
        if scanActivity == nil {
            scanActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Scanning a drive for recoverable files"
            )
        }
    }

    func stopScanClock() {
        bankedScanTime = elapsedScanTime
        scanStartedAt = nil
        if let scanActivity {
            ProcessInfo.processInfo.endActivity(scanActivity)
            self.scanActivity = nil
        }
    }

    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Defers preview work out of NSTableView's selection delegate; separate
    /// from previewTask, which owns the carve-and-decode itself.
    private var previewSelectionTask: Task<Void, Never>?
    private var pendingItems: [RecoveredItem] = []
    private var flushScheduled = false
    private var pauseGate: PauseGate?
    private var recoveryLog: RecoveryLog
    private var reviewLog: ReviewLog
    @Published var manifestStatus: String?
    /// Manifest entries whose data no longer matches the drive.
    @Published private(set) var staleReasons: [RecoveredItem.ID: RecoveryManifest.Staleness] = [:]
    /// Surfaced in the sidebar when recovery history can't be read or written.
    /// Recovery still works; only the "previously recovered" tracking is lost.
    @Published var logWarning: String?
    private var currentVolumeID: UInt64 = 0

    /// Stable identity for a found file across scans: volume serial (when the
    /// filesystem was recognized) plus location. ponytail: unrecognized
    /// filesystems fall back to the source name, which is weaker.
    private func logKey(for item: RecoveredItem) -> String {
        let volume = currentVolumeID != 0 ? "v\(currentVolumeID)" : "n\(item.source.displayName)"
        return "\(volume):\(item.byteOffset):\(item.byteLength)"
    }
    private let scanner = RecoveryScanner()

    init(
        recoveryLogURL: URL = RecoveryLog.defaultURL,
        reviewLogURL: URL = ReviewLog.defaultURL
    ) {
        // Injectable so tests can run the full scan-recover-rescan pipeline
        // without touching the real history files.
        recoveryLog = RecoveryLog.load(from: recoveryLogURL)
        reviewLog = ReviewLog.load(from: reviewLogURL)
        // An unreadable history file is surfaced immediately, not on first save:
        // the user should know tracking is off before they recover anything.
        logWarning = recoveryLog.loadError

        // Sweeps full-size previews left behind if a previous run crashed.
        Self.purgePreviewCache()

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
        target != nil && !isScanActive && state != .recovering
    }

    /// Kinds the scan actually looks for: the selection, or every kind when
    /// nothing is checked.
    var effectiveKinds: Set<MediaKind> {
        selectedKinds.isEmpty ? Set(MediaKind.allCases) : selectedKinds
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
        tableSelection = []
        clearPreview()
        progress = ScanProgress()
        scanNote = nil
        clearThumbnails()
        // A new drive means the previous scan's duration and counts no
        // longer apply. Go through stopScanClock so the power assertion is
        // released rather than leaked if a scan was still running.
        stopScanClock()
        bankedScanTime = 0
        scanSummary = nil
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

    // MARK: - Manifests

    /// Writes the current results to a JSON file so they can be recovered later
    /// without re-scanning. Exporting mid-scan is allowed and records the list
    /// as partial.
    func exportManifest() {
        guard !items.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export File List"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "file-list-\(Self.fileStamp()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let manifest = RecoveryManifest(
            items: items,
            volumeID: currentVolumeID,
            sourceName: items.first?.source.displayName ?? "",
            scanNote: scanNote,
            scanComplete: state == .finished
        )

        do {
            try manifest.encoded().write(to: url, options: .atomic)
            manifestStatus = "Exported \(items.count) entries to \(url.lastPathComponent)."
                + (manifest.scanComplete ? "" : " Scan was still running, so the list is partial.")
        } catch {
            manifestStatus = "Could not export: \(error.localizedDescription)"
        }
    }

    /// Loads a manifest and checks each entry against the drive currently
    /// selected. Nothing is recovered here — stale entries are shown, not
    /// dropped, so it's clear what's no longer on the disk.
    func importManifest() {
        guard let target else {
            manifestStatus = "Choose the drive this list came from first."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Open File List"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        state = .scanning
        startScanClock(resetTotal: true)
        manifestStatus = "Verifying against the drive…"

        let scanner = scanner
        scanTask = Task { [weak self] in
            do {
                let manifest = try RecoveryManifest.decode(try Data(contentsOf: url))
                // Re-planning opens the device (and prompts for authorization)
                // and re-reads the volume serial, which is what makes the
                // "same drive?" check meaningful.
                let plan = try await scanner.makePlan(for: target)
                guard let source = plan.regions.first?.source else {
                    throw RecoveryError.cannotOpen(url.path)
                }
                let verified = scanner.verify(manifest: manifest, against: source, volumeID: plan.volumeID)
                try Task.checkCancellation()
                await MainActor.run { self?.applyImported(verified, manifest: manifest) }
            } catch is CancellationError {
                await MainActor.run {
                    self?.stopScanClock()
                    self?.state = .idle
                }
            } catch {
                await MainActor.run {
                    self?.stopScanClock()
                    self?.state = .failed(error.localizedDescription)
                    self?.manifestStatus = nil
                }
            }
        }
    }

    private func applyImported(_ verified: [VerifiedEntry], manifest: RecoveryManifest) {
        currentVolumeID = manifest.volumeID
        scanNote = manifest.scanNote
        items = verified.map(\.item)
        staleReasons = Dictionary(
            uniqueKeysWithValues: verified.compactMap { entry in
                entry.staleness.map { (entry.item.id, $0) }
            }
        )
        // The manifest's recovered flags describe the machine that wrote it;
        // the local log stays authoritative for this one.
        for index in items.indices {
            items[index].previouslyRecovered =
                recoveryLog.contains(logKey(for: items[index])) || items[index].previouslyRecovered
        }
        selectedRecoveryIDs = []
        selectedItemID = nil
        tableSelection = []
        clearThumbnails()

        let stale = staleReasons.count
        let recoverable = items.count - stale
        manifestStatus = stale == 0
            ? "All \(items.count) entries verified against the drive."
            : "\(recoverable) of \(items.count) entries still match the drive; \(stale) changed and can't be recovered."
        stopScanClock()
        state = .finished
    }

    /// Stale entries can't be recovered — their bytes are gone or moved.
    func staleReason(for item: RecoveredItem) -> RecoveryManifest.Staleness? {
        staleReasons[item.id]
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
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
        tableSelection = []
        clearPreview()
        progress = ScanProgress()
        scanNote = nil
        clearThumbnails()
        scanSummary = nil
        state = .scanning
        startScanClock(resetTotal: true)

        var configured = scanner
        configured.fastScan = fastScan
        let scanner = configured
        let kinds = effectiveKinds
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
                    self.stopScanClock()
                    self.scanSummary = Self.summarize(self.items, duration: self.elapsedScanTime)
                    self.state = .finished
                    self.announceCompletion()
                }
            } catch is CancellationError {
                // No bounce and no summary: the user cancelled, so they know.
                await MainActor.run {
                    self?.stopScanClock()
                    self?.state = .idle
                }
            } catch {
                await MainActor.run {
                    self?.stopScanClock()
                    self?.state = .failed(error.localizedDescription)
                    self?.announceCompletion()
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        pauseGate = nil
        flushPendingItems()
        stopScanClock()
        state = .idle
    }

    func togglePause() {
        switch state {
        case .scanning:
            pauseGate?.setPaused(true)
            stopScanClock()
            state = .paused
        case .paused:
            pauseGate?.setPaused(false)
            // Resume without resetting: the banked time from before the pause
            // carries forward, so the total stays the whole scan's running time.
            startScanClock(resetTotal: false)
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
    /// Everything ever recovered from the current volume, whatever media type.
    /// The Recovered chip shows it so an off-type scan reads as "0 of 2,248
    /// in this scan" rather than looking like lost history.
    var volumeHistoryCount: Int {
        guard currentVolumeID != 0 else { return 0 }
        return recoveryLog.count(withPrefix: "v\(currentVolumeID):")
    }

    /// Test hook: records items as recovered exactly the way a real recovery
    /// does — same key scheme, same save path.
    func recordRecoveredForTesting(_ ids: Set<RecoveredItem.ID>) {
        for index in items.indices where ids.contains(items[index].id) {
            recoveryLog.record(logKey(for: items[index]))
        }
        recoveryLog.save()
    }

    /// Test hook: what the scan pipeline stamps onto each found item.
    func stampForTesting(_ item: RecoveredItem) -> RecoveredItem {
        markedIfPreviouslyRecovered(item)
    }

    /// Test hook: the volume component of history keys.
    func setVolumeIDForTesting(_ id: UInt64) {
        currentVolumeID = id
    }

    private func markedIfPreviouslyRecovered(_ item: RecoveredItem) -> RecoveredItem {
        var item = item
        let key = logKey(for: item)
        item.previouslyRecovered = recoveryLog.contains(key)
        item.reviewMark = reviewLog.mark(for: key)
        return item
    }

    /// Applies or clears a durable review mark on the given items and persists
    /// it, so the judgement survives a rescan of the same volume.
    func setReviewMark(_ mark: ReviewMark?, ids: Set<RecoveredItem.ID>) {
        for index in items.indices where ids.contains(items[index].id) {
            items[index].reviewMark = mark
            reviewLog.set(mark, for: logKey(for: items[index]))
            // A skipped file shouldn't stay queued for recovery.
            if mark != nil {
                selectedRecoveryIDs.remove(items[index].id)
            }
        }
        logWarning = reviewLog.save()
    }

    /// How many of the given items carry this mark — drives menu titles.
    func markCount(_ mark: ReviewMark, in ids: Set<RecoveredItem.ID>) -> Int {
        items.count { ids.contains($0.id) && $0.reviewMark == mark }
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
        let isVideo = item.kind.isVideoPreviewable
        // Videos have to be written out whole before a frame can be grabbed, so
        // they get a higher cap than images but still not an unlimited one.
        let sizeCap: UInt64 = isVideo ? 256 * 1024 * 1024 : 64 * 1024 * 1024
        guard item.kind.isPreviewable || isVideo,
              item.byteLength <= sizeCap,
              thumbnailsRequested.insert(item.id).inserted else { return }

        let scanner = scanner
        let itemID = item.id
        Task.detached(priority: .utility) { [weak self] in
            let url = Self.thumbnailURL(for: item)
            defer { try? FileManager.default.removeItem(at: url) }
            try? scanner.write(item, to: url)
            // NSImage isn't Sendable, so hand back PNG bytes and build the
            // image on the main actor.
            let data = isVideo
                ? await Self.videoThumbnailData(at: url, maxPixel: 320)
                : Self.thumbnailData(at: url, maxPixel: 320)
            guard let data else { return }
            await self?.setThumbnail(data, for: itemID)
        }
    }

    /// First decodable frame of a carved video. Tolerance is wide open so the
    /// generator can settle on the nearest keyframe instead of failing.
    private nonisolated static func videoThumbnailData(at url: URL, maxPixel: Int) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return pngData(cgImage)
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
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return pngData(cgImage)
    }

    private nonisolated static func pngData(_ cgImage: CGImage) -> Data? {
        guard let output = CFDataCreateMutable(nil, 0),
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

    /// Table selection binding. A single row previews; several rows leave the
    /// preview alone, since there's no one file to show.
    func setTableSelection(_ ids: Set<RecoveredItem.ID>) {
        tableSelection = ids
        if ids.count == 1, let only = ids.first {
            selectItem(only)
        } else if ids.isEmpty {
            selectItem(nil)
        }
    }

    /// Applies a recovery checkbox to every highlighted row when the clicked
    /// row is part of a multi-row selection, so shift-selecting a range and
    /// ticking one box marks the whole range.
    func setSelectedForRecoveryRespectingSelection(_ item: RecoveredItem, isSelected: Bool) {
        guard tableSelection.count > 1, tableSelection.contains(item.id) else {
            setSelectedForRecovery(item, isSelected: isSelected)
            return
        }
        setSelectedForRecovery(ids: tableSelection, isSelected: isSelected)
    }

    /// Command-click: add or remove one item without disturbing the rest.
    func toggleSelection(_ item: RecoveredItem) {
        if tableSelection.contains(item.id) {
            tableSelection.remove(item.id)
            if selectedItemID == item.id { selectedItemID = tableSelection.count == 1 ? tableSelection.first : nil }
        } else {
            tableSelection.insert(item.id)
            selectionAnchorID = item.id
        }
    }

    /// Shift-click: select everything between the anchor and this item in the
    /// order currently shown, so the range matches what the user sees rather
    /// than the underlying scan order.
    func extendSelection(to item: RecoveredItem) {
        let visible = filteredItems
        guard let end = visible.firstIndex(where: { $0.id == item.id }) else { return }
        let anchor = selectionAnchorID ?? selectedItemID
        guard let anchor, let start = visible.firstIndex(where: { $0.id == anchor }) else {
            setTableSelection([item.id])
            selectionAnchorID = item.id
            return
        }
        let range = start <= end ? start...end : end...start
        tableSelection = Set(visible[range].map(\.id))
    }

    /// Context-menu action over whatever rows are highlighted.
    func setSelectedForRecovery(ids: Set<RecoveredItem.ID>, isSelected: Bool) {
        // One pass over items to drop ids that aren't in the current results,
        // rather than a linear scan per id — that was O(items x selection), so
        // ticking a 10k-row range stalled the main actor.
        for id in Set(items.lazy.map(\.id)).intersection(ids) {
            setSelectedForRecovery(id: id, isSelected: isSelected)
        }
    }

    /// How many of the highlighted rows can actually be recovered — stale
    /// manifest entries can't, so a menu title of "Mark 40" would be a lie.
    func recoverableCount(in ids: Set<RecoveredItem.ID>) -> Int {
        ids.filter { staleReasons[$0] == nil }.count
    }

    func selectItem(_ itemID: RecoveredItem.ID?) {
        guard itemID != selectedItemID else { return }
        selectedItemID = itemID
        // Keep the highlight in step when selection comes from elsewhere
        // (arrow keys, the Preview column, gallery clicks).
        if let itemID { tableSelection = [itemID] } else { tableSelection = [] }
        selectionAnchorID = itemID

        // Table's selection binding calls this from inside NSTableView's
        // delegate. Tearing down preview state here publishes more changes, so
        // SwiftUI re-renders the table mid-delegate and AppKit warns about
        // reentrancy. The selection itself must land now for the row to
        // highlight; the preview can wait for the next runloop turn.
        previewSelectionTask?.cancel()
        previewSelectionTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard let item = selectedItem else {
                clearPreview()
                return
            }
            preparePreview(for: item)
        }
    }

    func isSelectedForRecovery(_ item: RecoveredItem) -> Bool {
        selectedRecoveryIDs.contains(item.id)
    }

    func setSelectedForRecovery(_ item: RecoveredItem, isSelected: Bool) {
        setSelectedForRecovery(id: item.id, isSelected: isSelected)
    }

    private func setSelectedForRecovery(id: RecoveredItem.ID, isSelected: Bool) {
        // A stale manifest entry's bytes are gone; recovering it would write
        // whatever now occupies that offset.
        guard staleReasons[id] == nil else { return }
        if isSelected {
            selectedRecoveryIDs.insert(id)
        } else {
            selectedRecoveryIDs.remove(id)
        }
    }

    /// Selects the visible (filtered) items, so a filename filter can scope
    /// exactly what gets recovered.
    /// Skips duplicates so one click doesn't queue the same photo several
    /// times. They stay individually selectable — the flag is a heuristic, so
    /// nothing is hidden or blocked on its strength.
    func selectAllForRecovery() {
        selectedRecoveryIDs.formUnion(
            filteredItems.lazy
                .filter { !$0.isDuplicate && $0.reviewMark == nil && self.staleReasons[$0.id] == nil }
                .map(\.id)
        )
    }

    var duplicateCount: Int {
        filteredItems.lazy.filter(\.isDuplicate).count
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
        var recovered: [RecoveredItem.ID] = []
        var failed = 0
        // Built once: a firstIndex scan per outcome is O(items x recovered), so
        // recovering thousands of files out of a large scan froze the UI at the
        // worst moment. uniquingKeysWith keeps firstIndex's "earliest wins".
        let indexByID = Dictionary(
            items.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for outcome in outcomes {
            guard let index = indexByID[outcome.id] else { continue }
            if let url = outcome.url {
                items[index].recoveredURL = url
                items[index].recoveryError = nil
                recoveryLog.record(logKey(for: items[index]))
                recovered.append(outcome.id)
            } else {
                items[index].recoveryError = outcome.error
                failed += 1
            }
        }
        if !recovered.isEmpty {
            logWarning = recoveryLog.save()
            if clearZipNameOnSuccess {
                zipFileName = ""
            }
            justRecoveredIDs = recovered
            recoveryFailureCount = failed
            showRecoveryCompletePrompt = true
        }
        state = .finished
    }

    /// Test hook: stage a set as the just-recovered files.
    func stageJustRecoveredForTesting(_ ids: [RecoveredItem.ID]) {
        justRecoveredIDs = ids
    }

    /// The completion prompt's "Uncheck" action: clears just the files this
    /// recovery wrote, leaving any other checked files queued.
    func uncheckRecoveredFiles() {
        selectedRecoveryIDs.subtract(justRecoveredIDs)
        justRecoveredIDs = []
    }

    func clearPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewImage = nil
        previewMetadata = ImageMetadata()
        previewFileURL = nil
        previewError = nil
    }

    /// EXIF/TIFF/GPS from the carved bytes. Reads the same temp file the preview
    /// already writes, so nothing has to be recovered first.
    nonisolated static func imageMetadata(at url: URL) -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ImageMetadata()
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var meta = ImageMetadata()

        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            meta.pixelSize = "\(w) x \(h)"
        }
        meta.captureDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        // Models often already include the make ("Canon EOS R5"); don't repeat it.
        meta.camera = [make, model].compactMap { $0 }.isEmpty ? nil
            : (model.map { m in make.map { m.hasPrefix($0) ? m : "\($0) \(m)" } ?? m } ?? make)
        meta.lens = exif[kCGImagePropertyExifLensModel] as? String
        if let speed = exif[kCGImagePropertyExifExposureTime] as? Double,
           let fnum = exif[kCGImagePropertyExifFNumber] as? Double {
            let shutter = speed >= 1 ? String(format: "%.0fs", speed) : "1/\(Int((1 / speed).rounded()))s"
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            meta.exposure = "\(shutter) · f/\(String(format: "%.1f", fnum))" + (iso.map { " · ISO \($0)" } ?? "")
        }
        // GPS stores unsigned degrees plus a hemisphere reference; apply the sign.
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            meta.coordinate = ImageMetadata.Coordinate(
                latitude: latRef == "S" ? -lat : lat,
                longitude: lonRef == "W" ? -lon : lon
            )
        }
        return meta
    }

    private func preparePreview(for item: RecoveredItem) {
        previewTask?.cancel()
        clearPreview()
        // clearPreview released the player and image, so the previous carve on
        // disk has no reader left. Drop it before writing the next one.
        Self.purgePreviewCache()

        let isVideo = item.kind.isVideoPreviewable
        guard item.kind.isPreviewable || isVideo else { return }

        let scanner = scanner
        previewTask = Task {
            do {
                let outputURL = Self.previewURL(for: item)
                try scanner.write(item, to: outputURL)
                try Task.checkCancellation()

                if isVideo {
                    // A carved video can be truncated or in a container AVFoundation
                    // won't decode, so ask the asset before handing it to a player.
                    let playable = (try? await AVURLAsset(url: outputURL).load(.isPlayable)) ?? false
                    try Task.checkCancellation()
                    await MainActor.run {
                        previewFileURL = outputURL
                        previewPlayer = playable ? AVPlayer(url: outputURL) : nil
                        previewError = playable ? nil : "\(item.kind.rawValue) playback not supported"
                    }
                    return
                }

                let image = NSImage(contentsOf: outputURL)
                let metadata = Self.imageMetadata(at: outputURL)

                await MainActor.run {
                    previewFileURL = outputURL
                    previewImage = image
                    previewMetadata = metadata
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

    private nonisolated static let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileRecoveryPreviews", isDirectory: true)

    /// Thumbnails get their own directory: they're written and deleted by
    /// detached tasks, so purging the preview cache must not race them.
    private nonisolated static let thumbnailDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileRecoveryThumbnails", isDirectory: true)

    private nonisolated static func previewURL(for item: RecoveredItem) -> URL {
        previewDirectory.appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
    }

    private nonisolated static func thumbnailURL(for item: RecoveredItem) -> URL {
        thumbnailDirectory.appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
    }

    /// Previews are full-size carves — a 2 GB video preview is a 2 GB temp file.
    /// Nothing deleted them, so browsing a long list filled the temp directory
    /// with a copy of every file the user clicked. Cleared whenever a new
    /// preview starts (the old one has already been torn down by clearPreview)
    /// and at launch, which also sweeps leftovers from a previous session.
    private nonisolated static func purgePreviewCache() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }
}
