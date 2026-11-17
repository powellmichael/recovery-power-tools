import AppKit
import Foundation

@MainActor
final class DuplicatesViewModel: ObservableObject {
    enum Stage: Equatable {
        case setup
        case scanning
        case results
        case failed(String)
    }

    enum KeepRule {
        case oldest, newest
    }

    @Published var folders: [URL] = []
    /// Bytes; files smaller than this are ignored.
    @Published var minimumSize: UInt64 = 1
    @Published private(set) var stage: Stage = .setup
    @Published private(set) var progress = DuplicateProgress()
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var filesExamined = 0
    @Published private(set) var unreadable = 0
    /// Files marked to be moved to the Trash.
    @Published private(set) var marked: Set<URL> = []
    /// What the last Move to Trash did, until dismissed.
    @Published var trashReport: TrashReport?

    struct TrashReport: Equatable {
        var moved = 0
        var freedBytes: UInt64 = 0
        var failures: [String] = []
    }

    private var scanTask: Task<Void, Never>?
    private let finder = DuplicateFinder()
    /// Injectable so tests delete temp files instead of filling the Trash.
    private let trash: @Sendable (URL) throws -> Void

    init(trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.trash = trash
    }

    // MARK: - Folders

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders to Check"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    func addFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(url) {
            folders.append(url)
        }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    // MARK: - Scanning

    func startScan() {
        guard !folders.isEmpty, stage != .scanning else { return }
        groups = []
        marked = []
        trashReport = nil
        progress = DuplicateProgress()
        stage = .scanning
        let finder = finder, roots = folders, minimum = minimumSize
        scanTask = Task { [weak self] in
            do {
                let result = try await finder.find(in: roots, minimumSize: minimum) { update in
                    await MainActor.run { self?.progress = update }
                }
                guard let self else { return }
                groups = result.groups
                filesExamined = result.filesExamined
                unreadable = result.unreadable
                stage = .results
            } catch is CancellationError {
                self?.stage = .setup
            } catch {
                self?.stage = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    func backToSetup() {
        scanTask?.cancel()
        groups = []
        marked = []
        trashReport = nil
        stage = .setup
    }

    // MARK: - Marking

    var reclaimableBytes: UInt64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }

    var markedBytes: UInt64 {
        groups.reduce(0) { total, group in
            total + group.size * UInt64(group.files.count { marked.contains($0.url) })
        }
    }

    /// The copy suggested to keep: the oldest, as the likeliest original.
    func suggestedKeeper(in group: DuplicateGroup, rule: KeepRule = .oldest) -> DuplicateFile? {
        group.files.min { a, b in
            let left = a.modified ?? .distantFuture, right = b.modified ?? .distantFuture
            if left != right { return rule == .oldest ? left < right : left > right }
            return a.url.path < b.url.path
        }
    }

    /// Marks or unmarks one file. Refuses to mark the last unmarked copy in a
    /// group: one copy of everything always stays. Returns false when refused.
    @discardableResult
    func setMarked(_ isMarked: Bool, file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        guard isMarked else {
            marked.remove(file.url)
            return true
        }
        let othersUnmarked = group.files.contains { $0.url != file.url && !marked.contains($0.url) }
        guard othersUnmarked else { return false }
        marked.insert(file.url)
        return true
    }

    func canMark(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        marked.contains(file.url) || group.files.contains { $0.url != file.url && !marked.contains($0.url) }
    }

    /// Marks every copy except one per group.
    func markAllDuplicates(keeping rule: KeepRule) {
        var next = Set<URL>()
        for group in groups {
            guard let keeper = suggestedKeeper(in: group, rule: rule) else { continue }
            for file in group.files where file.url != keeper.url {
                next.insert(file.url)
            }
        }
        marked = next
    }

    func clearMarks() {
        marked = []
    }

    // MARK: - Removing

    /// Moves the marked files to the Trash, where they can be put back.
    /// Each group is re-checked first: files are only moved while an unmarked
    /// copy still exists on disk, and a file that changed since the scan is
    /// left alone, because it may no longer be a duplicate.
    func moveMarkedToTrash() {
        var report = TrashReport()
        var remaining: [DuplicateGroup] = []
        for var group in groups {
            let doomed = group.files.filter { marked.contains($0.url) }
            guard !doomed.isEmpty else {
                remaining.append(group)
                continue
            }
            let keeperSurvives = group.files.contains { !marked.contains($0.url) && Self.isUnchanged($0) }
            for file in doomed {
                guard keeperSurvives else {
                    report.failures.append("\(file.url.lastPathComponent): the copy to keep is missing or has changed, so this was left in place.")
                    continue
                }
                guard Self.isUnchanged(file) else {
                    report.failures.append("\(file.url.lastPathComponent): changed since the scan, so it was left in place.")
                    continue
                }
                do {
                    try trash(file.url)
                    report.moved += 1
                    report.freedBytes += file.size
                    group.files.removeAll { $0.url == file.url }
                } catch {
                    report.failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if group.files.count > 1 { remaining.append(group) }
        }
        groups = remaining
        marked = []
        trashReport = report
    }

    /// Same size and modification time as when it was scanned.
    /// Read through FileManager, not URL.resourceValues: a URL caches the
    /// values it was enumerated with and would report the file as unchanged
    /// even after it was edited or deleted.
    private static func isUnchanged(_ file: DuplicateFile) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? UInt64 else { return false }
        return size == file.size && attributes[.modificationDate] as? Date == file.modified
    }
}
