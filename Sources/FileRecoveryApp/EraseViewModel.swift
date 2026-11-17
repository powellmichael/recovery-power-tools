import AppKit
import Foundation

@MainActor
final class EraseViewModel: ObservableObject {
    enum Job: String, CaseIterable, Identifiable {
        case freeSpace, files, volume
        var id: String { rawValue }

        var label: String {
            switch self {
            case .freeSpace: "Erase Free Space"
            case .files: "Shred Files"
            case .volume: "Erase Entire Volume"
            }
        }
    }

    enum Stage: Equatable {
        case setup
        case erasing
        case verifying
        case done
        case failed(String)
    }

    /// What the finished job did, in the words shown on the result screen.
    struct Outcome: Equatable {
        var succeeded = true
        var headline = ""
        var details: [String] = []
        /// Files a recovery scan still found afterwards. Nil when no check ran.
        var stillRecoverable: Int?
        var checkNote: String?
    }

    /// The least destructive job is the default.
    @Published var job: Job = .freeSpace
    @Published var selectedDeviceID: String?
    @Published var format: EraseFormat = .exfat
    @Published private(set) var devices: [ExternalDevice] = []
    @Published private(set) var isLoadingDevices = false
    @Published private(set) var files: [URL] = []
    @Published private(set) var fileNotice: String?
    @Published private(set) var stage: Stage = .setup
    @Published private(set) var progress = EraseProgress()
    @Published private(set) var checkFraction: Double = 0
    @Published private(set) var outcome = Outcome()

    private var task: Task<Void, Never>?

    // MARK: - Targets

    /// Volumes the current job can act on: partitions holding a filesystem
    /// macOS can format over, and for free space, one it can write to now.
    ///
    /// ponytail: APFS containers, unformatted partitions and cards with no
    /// partition table are left out. An APFS container can hold several
    /// volumes behind one name-less entry, which is the wrong thing to offer
    /// behind a typed confirmation. Add them when each can be shown and
    /// confirmed by name.
    var candidates: [ExternalDevice] {
        devices.filter { device in
            guard !device.isWholeDisk, device.filesystemName != nil,
                  device.contentType?.lowercased() != "apple_apfs" else { return false }
            if job == .volume { return true }
            guard let mount = device.mountPoint else { return false }
            return access(mount, W_OK) == 0
        }
    }

    var selectedDevice: ExternalDevice? {
        candidates.first { $0.id == selectedDeviceID }
    }

    /// What the user must type before a whole volume is erased.
    var confirmationText: String {
        guard let device = selectedDevice else { return "" }
        if let name = device.volumeName, !name.isEmpty { return name }
        return device.identifier
    }

    var canStart: Bool {
        guard stage == .setup else { return false }
        return job == .files ? !files.isEmpty : selectedDevice != nil
    }

    func refreshDevices() {
        isLoadingDevices = true
        Task {
            let found = await Task.detached { DeviceDiscovery.externalDevices() }.value
            devices = found
            isLoadingDevices = false
            if selectedDevice == nil { selectedDeviceID = nil }
        }
    }

    func select(_ device: ExternalDevice) {
        selectedDeviceID = device.id
        format = .matching(device)
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Files or Folders to Shred"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    /// Only items on external drives are accepted. The eraser checks again
    /// before it writes anything.
    func addFiles(_ urls: [URL]) {
        var externalByVolume: [String: Bool] = [:]
        var refused = 0
        for url in urls where !files.contains(url) {
            let volume = DeviceDiscovery.bsdName(forPath: url.path) ?? ""
            let external = externalByVolume[volume] ?? SecureEraser.isOnExternalDisk(url)
            externalByVolume[volume] = external
            if external { files.append(url) } else { refused += 1 }
        }
        fileNotice = refused == 0 ? nil
            : "\(refused) item\(refused == 1 ? " is" : "s are") not on an external drive and \(refused == 1 ? "was" : "were") not added. Only files on external drives and cards can be shredded."
    }

    func removeFile(_ url: URL) {
        files.removeAll { $0 == url }
    }

    // MARK: - Running

    /// Starts the chosen job. The view asks for confirmation first.
    func start() {
        guard canStart else { return }
        let job = job, device = selectedDevice, files = files, format = format
        progress = EraseProgress()
        checkFraction = 0
        outcome = Outcome()
        stage = .erasing

        let report: @Sendable (EraseProgress) -> Void = { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }
        task = Task { [weak self] in
            // A drive that sleeps half-way through is a half-erased drive.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Erasing a drive"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                var result = Outcome()
                var check: ExternalDevice?
                switch job {
                case .files:
                    let shredded = try await SecureEraser.shred(files, progress: report)
                    result.succeeded = shredded.failures.isEmpty
                    result.headline = "Shredded \(shredded.files.formatted()) file\(shredded.files == 1 ? "" : "s"), "
                        + ByteCountFormatter.string(fromByteCount: Int64(shredded.bytes), countStyle: .file)
                    result.details = shredded.failures
                case .freeSpace:
                    guard let device else { return }
                    try await SecureEraser.wipeFreeSpace(device, progress: report)
                    result.headline = "Free space on \(device.userFacingName) was overwritten"
                    result.details = ["The files on the drive were not changed."]
                    check = device
                case .volume:
                    guard let device else { return }
                    if try await SecureEraser.eraseVolume(device, format: format, progress: report) {
                        result.headline = "\(device.userFacingName) was erased"
                        result.details = ["It was formatted as \(format.label) and all of its space was overwritten."]
                        check = device
                    } else {
                        result.succeeded = false
                        result.headline = "\(device.userFacingName) was formatted, but the overwrite was stopped early"
                        result.details = ["The drive is empty and usable, but files that were on it can still be recovered from the part that was not overwritten. Erase it again to finish."]
                    }
                }
                if let check {
                    self?.stage = .verifying
                    do {
                        let count = try await Self.recoverableCount(on: check) { fraction in
                            Task { @MainActor in self?.checkFraction = fraction }
                        }
                        result.stillRecoverable = count
                        if count > 0 { result.succeeded = false }
                    } catch is CancellationError {
                        result.checkNote = "The recovery check was skipped."
                    } catch {
                        result.checkNote = "The recovery check could not run: \(error.localizedDescription)"
                    }
                }
                guard let self else { return }
                outcome = result
                self.files = []
                stage = .done
                refreshDevices()
            } catch is CancellationError {
                self?.outcome = Outcome(
                    succeeded: false,
                    headline: "Stopped before finishing",
                    details: [job == .files
                        ? "Files already shredded are gone. The rest were left as they were."
                        : "The filler was removed. The part of the free space that was not reached was not overwritten."]
                )
                self?.files.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
                self?.stage = .done
            } catch {
                self?.stage = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the erase, or skips the recovery check once the erase is done.
    func cancel() {
        task?.cancel()
    }

    func reset() {
        task?.cancel()
        stage = .setup
        fileNotice = nil
    }

    /// Scans the erased volume with the recovery engine and counts what it
    /// can still find. This is the proof the tool offers.
    private nonisolated static func recoverableCount(
        on device: ExternalDevice,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let scanner = RecoveryScanner()
        let plan = try await scanner.makePlan(for: .device(device))
        let items = try await scanner.scan(
            plan: plan,
            selectedKinds: Set(MediaKind.allCases),
            progress: { progress($0.fraction) },
            itemFound: { _ in }
        )
        try Task.checkCancellation()
        return items.count
    }
}
