import AppKit
import Foundation

@MainActor
final class CardCopyViewModel: ObservableObject {
    enum Stage: Equatable {
        case setup
        case copying
        case done
        case failed(String)
    }

    static let maxDestinations = 2

    @Published private(set) var source: URL?
    @Published private(set) var destinations: [URL] = []
    /// Why the chosen folders cannot be used, if they cannot.
    @Published private(set) var problem: String?
    @Published private(set) var stage: Stage = .setup
    @Published private(set) var progress = CopyProgress()
    @Published private(set) var report = CopyReport()
    @Published private(set) var startedAt: Date?

    private var task: Task<Void, Never>?

    var canStart: Bool {
        stage == .setup && source != nil && !destinations.isEmpty && problem == nil
    }

    /// The folder made in each destination: the source's name and today's date.
    var folderName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(source?.lastPathComponent ?? "Copy") \(formatter.string(from: Date()))"
    }

    var remainingLabel: String? {
        guard stage == .copying, let startedAt, let fraction = progress.fraction else { return nil }
        return RecoveryViewModel.remainingLabel(elapsed: Date().timeIntervalSince(startedAt), fraction: fraction)
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Card or Folder to Copy"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(url)
    }

    func setSource(_ url: URL) {
        source = url
        check()
    }

    func addDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Save a Copy"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addDestination(url)
    }

    func addDestination(_ url: URL) {
        guard destinations.count < Self.maxDestinations, !destinations.contains(url) else { return }
        destinations.append(url)
        check()
    }

    func removeDestination(_ url: URL) {
        destinations.removeAll { $0 == url }
        check()
    }

    private func check() {
        guard let source else {
            problem = nil
            return
        }
        do {
            try VerifiedCopier.checkDestinations(destinations, source: source)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func start() {
        check()
        guard canStart, let source else { return }
        let destinations = destinations, name = folderName
        progress = CopyProgress()
        report = CopyReport()
        startedAt = Date()
        stage = .copying
        task = Task { [weak self] in
            // A sleeping Mac would leave the card half copied.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Copying and verifying files"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let finished = try await VerifiedCopier.copy(from: source, to: destinations, folderName: name) { update in
                    Task { @MainActor in
                        guard let self, self.stage == .copying else { return }
                        self.progress = update
                    }
                }
                self?.report = finished
                self?.stage = .done
            } catch is CancellationError {
                self?.stage = .setup
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
    }
}
