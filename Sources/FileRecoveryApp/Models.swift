import Foundation

enum MediaKind: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case heic = "HEIC"
    case raw = "RAW"
    case bmp = "BMP"
    case video = "MP4 / MOV"
    case avi = "AVI"
    case wmv = "WMV / ASF"
    case flv = "FLV"
    case webm = "WebM / MKV"
    case mpeg = "MPEG"
    case zip = "ZIP"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .raw: "tif"
        case .bmp: "bmp"
        case .video: "mp4"
        case .avi: "avi"
        case .wmv: "wmv"
        case .flv: "flv"
        case .webm: "webm"
        case .mpeg: "mpg"
        case .zip: "zip"
        }
    }

    /// Kinds the app can render an image preview for.
    var isPreviewable: Bool {
        switch self {
        case .jpeg, .png, .heic, .bmp: true
        default: false
        }
    }

    /// Kinds we hand to AVPlayer. It rejects what it can't decode (FLV, most
    /// WMV), so playability is confirmed per file rather than assumed here.
    var isVideoPreviewable: Bool {
        switch self {
        case .video, .avi, .wmv, .flv, .webm, .mpeg: true
        default: false
        }
    }

    /// Extensions that mean "this whole source file already is this kind".
    var knownExtensions: Set<String> {
        switch self {
        case .jpeg: ["jpg", "jpeg"]
        case .png: ["png"]
        case .heic: ["heic", "heif"]
        case .raw: ["tif", "tiff", "nef", "cr2", "arw", "dng", "3fr", "raf"]
        case .bmp: ["bmp"]
        case .video: ["mov", "mp4", "m4v", "3gp", "3g2"]
        case .avi: ["avi"]
        case .wmv: ["wmv", "asf"]
        case .flv: ["flv"]
        case .webm: ["webm", "mkv"]
        case .mpeg: ["mpg", "mpeg"]
        case .zip: ["zip"]
        }
    }
}

enum MediaCategory: String, CaseIterable, Identifiable, Sendable {
    case images = "Images"
    case video = "Video"
    case archives = "Archives"

    var id: String { rawValue }

    var kinds: [MediaKind] {
        switch self {
        case .images: [.jpeg, .png, .heic, .raw, .bmp]
        case .video: [.video, .avi, .wmv, .flv, .webm, .mpeg]
        case .archives: [.zip]
        }
    }
}

enum ScanTarget: Equatable, Sendable {
    case path(URL)
    case device(ExternalDevice)
}

struct ScanRegion: Sendable {
    let source: ScanSource
    let range: Range<UInt64>
}

struct ScanPlan: Sendable {
    let regions: [ScanRegion]
    let note: String?
    var deletedFiles: [UInt64: DeletedFileEntry] = [:]
    /// Volume serial when the filesystem was recognized; 0 otherwise.
    var volumeID: UInt64 = 0
}

enum ResultsViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case gallery = "Gallery"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .gallery: "square.grid.2x2"
        }
    }
}

enum RecoveredVisibility: String, CaseIterable, Identifiable {
    case all = "All"
    case unrecovered = "New"
    case recovered = "Recovered"
    var id: String { rawValue }
}

/// Persistent record of recovered files, keyed by volume serial + location,
/// so repeat scans can show what was already recovered.
struct RecoveryLog {
    private var keys: Set<String>

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileRecovery", isDirectory: true)
            .appendingPathComponent("recovered.json")
    }

    static func load() -> RecoveryLog {
        guard let data = try? Data(contentsOf: fileURL),
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return RecoveryLog(keys: [])
        }
        return RecoveryLog(keys: keys)
    }

    func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    mutating func record(_ key: String) {
        keys.insert(key)
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(keys).write(to: Self.fileURL)
    }
}

struct RecoveredItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let kind: MediaKind
    let source: ScanSource
    let byteOffset: UInt64
    let byteLength: UInt64
    let fileExtension: String
    let originalFilename: String?
    /// Fragmented-file data runs (NTFS); nil = contiguous at byteOffset.
    var segments: [Range<UInt64>]? = nil
    var recoveredURL: URL?
    var recoveryError: String?
    /// True when the recovery log says this file was recovered in a past run.
    var previouslyRecovered = false

    var displayName: String {
        originalFilename
            ?? "\(kind.rawValue.split(separator: " ").first.map(String.init)?.lowercased() ?? "item")-\(String(byteOffset, radix: 16)).\(fileExtension)"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteLength), countStyle: .file)
    }

    var filenameLabel: String {
        originalFilename ?? "Not Available"
    }
}

struct ScanProgress: Sendable {
    var bytesScanned: UInt64 = 0
    var totalBytes: UInt64 = 0
    var currentPath: String = ""

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesScanned) / Double(totalBytes))
    }
}

enum ScanState: Equatable {
    case idle
    case scanning
    case paused
    case recovering
    case finished
    case failed(String)
}

/// Cross-thread pause switch checked by the scanner between read chunks.
final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        lock.withLock { paused }
    }

    func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }
}
