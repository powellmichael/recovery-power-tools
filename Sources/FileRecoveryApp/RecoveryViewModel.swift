import AppKit
import Foundation
import SwiftUI

@MainActor
final class RecoveryViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    @Published var selectedKinds: Set<MediaKind> = Set(MediaKind.allCases)
    @Published var items: [RecoveredItem] = []
    @Published var progress = ScanProgress()
    @Published var state: ScanState = .idle
    @Published var selectedItemID: RecoveredItem.ID?

    private var scanTask: Task<Void, Never>?
    private let scanner = RecoveryScanner()

    var canScan: Bool {
        sourceURL != nil && state != .scanning && state != .recovering && !selectedKinds.isEmpty
    }

    var canRecover: Bool {
        destinationURL != nil && !items.isEmpty && state != .scanning && state != .recovering
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

        if panel.runModal() == .OK {
            sourceURL = panel.url
            items = []
            progress = ScanProgress()
            state = .idle
        }
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

    func startScan() {
        guard let sourceURL else { return }
        scanTask?.cancel()
        items = []
        progress = ScanProgress()
        state = .scanning

        scanTask = Task {
            do {
                let found = try await scanner.scan(
                    source: sourceURL,
                    selectedKinds: selectedKinds,
                    progress: { [weak self] newProgress in
                        await MainActor.run {
                            self?.progress = newProgress
                        }
                    },
                    itemFound: { [weak self] item in
                        await MainActor.run {
                            guard let self else { return }
                            self.items.append(item)
                            self.selectedItemID = self.selectedItemID ?? item.id
                        }
                    }
                )

                await MainActor.run {
                    let existingIDs = Set(items.map(\.id))
                    let missing = found.filter { !existingIDs.contains($0.id) }
                    items.append(contentsOf: missing)
                    state = .finished
                }
            } catch is CancellationError {
                await MainActor.run {
                    state = .idle
                }
            } catch {
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
    }

    func recoverAll() {
        guard let destinationURL else { return }
        state = .recovering

        Task {
            do {
                var updated = items
                for index in updated.indices {
                    try Task.checkCancellation()
                    let output = try scanner.recover(updated[index], to: destinationURL)
                    updated[index].recoveredURL = output
                }

                await MainActor.run {
                    items = updated
                    state = .finished
                }
            } catch {
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
