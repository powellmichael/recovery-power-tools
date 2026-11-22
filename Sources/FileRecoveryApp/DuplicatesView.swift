import AppKit
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers
import SwiftUI

/// Find Duplicates: choose folders, compare, then pick which copies go to
/// the Trash. Nothing is ever deleted outright, and one copy always stays.
struct DuplicatesView: View {
    @ObservedObject var viewModel: DuplicatesViewModel
    let showHome: () -> Void
    @State private var confirmsTrash = false
    @State private var quickLookURL: URL?

    var body: some View {
        Group {
            switch viewModel.stage {
            case .setup, .failed:
                setup
            case .scanning:
                scanning
            case .results:
                results
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Button(action: showHome) {
                        Label("All Tools", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    HelpLink(topic: "duplicates")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Find duplicate files")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Finds files whose contents are exactly identical, whatever they are named.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if case .failed(let message) = viewModel.stage {
                    NoticeBand(text: message, systemImage: "exclamationmark.triangle.fill", tint: .red)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Where to look")
                        .font(.headline)
                    if viewModel.folders.isEmpty {
                        Text("No folders chosen yet. Add one or more folders or drives; everything inside them is compared.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(viewModel.folders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.tint)
                            Text(folder.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                viewModel.removeFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(folder.lastPathComponent)")
                        }
                    }
                    Button("Add Folders…") { viewModel.chooseFolders() }

                    Divider()

                    Picker("Ignore files smaller than", selection: $viewModel.minimumSize) {
                        Text("Nothing (check every file)").tag(UInt64(1))
                        Text("100 KB").tag(UInt64(100_000))
                        Text("1 MB").tag(UInt64(1_000_000))
                        Text("10 MB").tag(UInt64(10_000_000))
                    }
                    .frame(maxWidth: 380)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                Label {
                    Text("Nothing is removed by searching. Hidden files, and the insides of apps and libraries such as Photos, are left out.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    viewModel.startScan()
                } label: {
                    Label("Find Duplicates", systemImage: "magnifyingglass")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.folders.isEmpty)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Scanning

    private var scanning: some View {
        VStack(spacing: 18) {
            Text(viewModel.progress.phase == .listing ? "Listing files…" : "Comparing files…")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            if let fraction = viewModel.progress.fraction {
                ProgressView(value: fraction)
                    .frame(maxWidth: 420)
            } else {
                ProgressView()
            }
            Text(scanDetail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel", role: .cancel) { viewModel.cancelScan() }
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanDetail: String {
        let progress = viewModel.progress
        if progress.phase == .listing {
            return "\(progress.filesListed.formatted()) files found so far"
        }
        let done = ByteCountFormatter.string(fromByteCount: Int64(progress.bytesCompared), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(progress.bytesToCompare), countStyle: .file)
        return "\(done) of \(total) that share a size with another file"
    }

    // MARK: - Results

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duplicate Files")
                        .font(.title2.weight(.semibold))
                    Text(resultsSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.groups.isEmpty {
                    Menu {
                        Button("Mark All, Keeping the Oldest Copy") { viewModel.markAllDuplicates(keeping: .oldest) }
                        Button("Mark All, Keeping the Newest Copy") { viewModel.markAllDuplicates(keeping: .newest) }
                        Divider()
                        Button("Clear All Marks") { viewModel.clearMarks() }
                            .disabled(viewModel.marked.isEmpty)
                    } label: {
                        Label("Mark", systemImage: "checklist")
                    }
                    .fixedSize()
                    .help("Mark every extra copy for the Trash, leaving one in each group")
                }
                Button("Search Again") { viewModel.backToSetup() }
                Button("All Tools", action: showHome)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

            Divider()

            if let report = viewModel.trashReport {
                trashReportBand(report)
            }

            if viewModel.groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(viewModel.trashReport == nil ? "No duplicates found" : "No duplicates left")
                        .font(.title3.weight(.medium))
                    Text("\(viewModel.filesExamined.formatted()) files were checked.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.groups) { group in
                        Section {
                            ForEach(group.files) { file in
                                row(file, in: group)
                            }
                        } header: {
                            HStack(spacing: 10) {
                                // The copies are identical, so one picture
                                // stands for the whole group.
                                if let sample = viewModel.suggestedKeeper(in: group) ?? group.files.first {
                                    DuplicateThumbnail(url: sample.url)
                                }
                                Text("\(group.files.count) identical copies · \(ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)) each")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.inset)

                Divider()
                actionBar
            }
        }
    }

    private var resultsSummary: String {
        var text = "\(viewModel.groups.count.formatted()) groups among \(viewModel.filesExamined.formatted()) files · up to "
            + ByteCountFormatter.string(fromByteCount: Int64(viewModel.reclaimableBytes), countStyle: .file)
            + " can be freed"
        if viewModel.unreadable > 0 {
            text += " · \(viewModel.unreadable.formatted()) could not be read"
        }
        return text
    }

    private func row(_ file: DuplicateFile, in group: DuplicateGroup) -> some View {
        let isMarked = viewModel.marked.contains(file.url)
        let isKeeper = viewModel.suggestedKeeper(in: group)?.url == file.url
        return HStack(spacing: 10) {
            Toggle("Move \(file.url.lastPathComponent) to the Trash", isOn: Binding(
                get: { isMarked },
                set: { viewModel.setMarked($0, file: file, in: group) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(!viewModel.canMark(file, in: group))
            .help(viewModel.canMark(file, in: group)
                  ? "Mark this copy to be moved to the Trash"
                  : "This is the last copy left unmarked. One copy always stays.")

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(isMarked)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if isMarked {
                StatusBadge(text: "To Trash", tint: .red)
            } else if isKeeper {
                StatusBadge(text: "Oldest", tint: .green, help: "The oldest copy, and the one kept by Mark All, Keeping the Oldest Copy")
            }
            if let modified = file.modified {
                Text(modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                quickLookURL = file.url
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Quick Look")
            .accessibilityLabel("Quick Look \(file.url.lastPathComponent)")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(file.url.lastPathComponent) in Finder")
        }
        .padding(.vertical, 2)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.marked.isEmpty
                     ? "No files marked"
                     : "\(viewModel.marked.count.formatted()) file\(viewModel.marked.count == 1 ? "" : "s") marked · frees \(ByteCountFormatter.string(fromByteCount: Int64(viewModel.markedBytes), countStyle: .file))")
                    .font(.callout.weight(.semibold))
                Text("Marked files go to the Trash, where you can put them back. One copy of every file always stays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                confirmsTrash = true
            } label: {
                Label("Move to Trash…", systemImage: "trash")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.marked.isEmpty)
            .confirmationDialog(
                "Move \(viewModel.marked.count.formatted()) file\(viewModel.marked.count == 1 ? "" : "s") to the Trash?",
                isPresented: $confirmsTrash,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { viewModel.moveMarkedToTrash() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("An identical copy of each one stays where it is. You can put files back from the Trash until you empty it.")
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private func trashReportBand(_ report: DuplicatesViewModel.TrashReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Moved \(report.moved.formatted()) file\(report.moved == 1 ? "" : "s") to the Trash, \(ByteCountFormatter.string(fromByteCount: Int64(report.freedBytes), countStyle: .file)). The space is freed when you empty the Trash.")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(report.failures.prefix(5), id: \.self) { failure in
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.failures.count > 5 {
                    Text("…and \(report.failures.count - 5) more not moved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                viewModel.trashReport = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background((report.failures.isEmpty ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// A Quick Look thumbnail of one file, with the file's icon until it loads
/// or when the file type has no preview.
private struct DuplicateThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    private static let side: CGFloat = 48
    /// Scrolling a long list back and forth should not redraw every picture.
    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            .task(id: url) {
                // A thumbnail of a text file or a spreadsheet is a blank
                // page at this size; the file's icon says more.
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf) else { return }
                if let cached = Self.cache.object(forKey: url as NSURL) {
                    image = cached
                    return
                }
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: Self.side, height: Self.side),
                    scale: NSScreen.main?.backingScaleFactor ?? 2,
                    representationTypes: .thumbnail
                )
                guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
                Self.cache.setObject(thumbnail.nsImage, forKey: url as NSURL)
                image = thumbnail.nsImage
            }
    }
}
