import AppKit
import Foundation

@MainActor
final class ImagingViewModel: ObservableObject {
    enum Stage: Equatable {
        case setup
        case copying
        case done
        case failed(String)
    }

    @Published var selectedDeviceID: String?
    @Published private(set) var devices: [ExternalDevice] = []
    @Published private(set) var isLoadingDevices = false
    @Published private(set) var destination: URL?
    /// Why the chosen destination cannot be used, if it cannot.
    @Published private(set) var destinationProblem: String?
    @Published private(set) var stage: Stage = .setup
    @Published private(set) var progress = ImagingProgress()
    @Published private(set) var result: ImagingResult?
    @Published private(set) var startedAt: Date?

    private var task: Task<Void, Never>?

    var selectedDevice: ExternalDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var canStart: Bool {
        stage == .setup && selectedDevice != nil && destination != nil && destinationProblem == nil
    }

    var remainingLabel: String? {
        guard stage == .copying, let startedAt else { return nil }
        return RecoveryViewModel.remainingLabel(elapsed: Date().timeIntervalSince(startedAt), fraction: progress.fraction)
    }

    func refreshDevices() {
        isLoadingDevices = true
        Task {
            devices = await Task.detached { DeviceDiscovery.externalDevices() }.value
            isLoadingDevices = false
            if selectedDevice == nil { selectedDeviceID = nil }
            checkDestination()
        }
    }

    func select(_ device: ExternalDevice) {
        selectedDeviceID = device.id
        checkDestination()
    }

    func chooseDestination() {
        guard let device = selectedDevice else { return }
        let panel = NSSavePanel()
        panel.title = "Save Drive Image"
        panel.nameFieldStringValue = "\(device.userFacingName).img"
        panel.canCreateDirectories = true
        panel.message = "Needs \(ByteCountFormatter.string(fromByteCount: Int64(device.size), countStyle: .file)) of free space, on a different drive from the one being copied."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        checkDestination()
    }

    private func checkDestination() {
        guard let device = selectedDevice, let destination else {
            destinationProblem = nil
            return
        }
        do {
            try DriveImager.checkDestination(destination, for: device)
            destinationProblem = nil
        } catch {
            destinationProblem = error.localizedDescription
        }
    }

    func start() {
        checkDestination()
        guard canStart, let device = selectedDevice, let destination else { return }
        progress = ImagingProgress(total: device.size)
        result = nil
        startedAt = nil
        stage = .copying
        task = Task { [weak self] in
            // A sleeping Mac would stop a copy that can run for hours.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Copying a drive to an image file"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let finished = try await Self.copy(device, to: destination) { update in
                    Task { @MainActor in
                        guard let self, self.stage == .copying else { return }
                        // The clock starts once the password prompt is done.
                        if self.startedAt == nil { self.startedAt = Date() }
                        self.progress = update
                    }
                }
                self?.result = finished
                self?.stage = .done
            } catch {
                self?.stage = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        task?.cancel()
        stage = .setup
        destination = nil
        destinationProblem = nil
    }

    private nonisolated static func copy(
        _ device: ExternalDevice,
        to url: URL,
        progress: @escaping @Sendable (ImagingProgress) -> Void
    ) async throws -> ImagingResult {
        // Opens read-only through authopen, which asks for the password.
        let source = try ScanSource(devicePath: device.rawDevicePath, displayName: device.displayName)
        return try await DriveImager.copy(source, to: url, progress: progress)
    }
}
