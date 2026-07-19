import Foundation

enum MediaKind: String, CaseIterable, Identifiable, Codable, Sendable {
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
///
/// This file is irreplaceable — it's the only record that a given deleted file
/// was already pulled off a drive. So an unreadable file is never treated as an
/// empty one: that would let the next save overwrite thousands of records with
/// a handful. A load failure sets `isReadable = false`, which blocks saving
/// until a human deals with it.
struct RecoveryLog {
    private var keys: Set<String>
    /// Injectable so tests never touch the real history file.
    private let fileURL: URL
    /// False when the file exists but couldn't be parsed. Saving is refused.
    private(set) var isReadable = true
    private(set) var loadError: String?

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileRecovery", isDirectory: true)
            .appendingPathComponent("recovered.json")
    }

    static func load(from url: URL = defaultURL) -> RecoveryLog {
        // No file yet is the normal first-run case, not a failure.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RecoveryLog(keys: [], fileURL: url)
        }
        do {
            let data = try Data(contentsOf: url)
            let keys = try JSONDecoder().decode(Set<String>.self, from: data)
            return RecoveryLog(keys: keys, fileURL: url)
        } catch {
            var log = RecoveryLog(keys: [], fileURL: url)
            log.isReadable = false
            log.loadError = "Recovery history at \(url.path) could not be read "
                + "(\(error.localizedDescription)). It will not be overwritten. "
                + "Move or repair the file to resume tracking."
            return log
        }
    }

    func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    mutating func record(_ key: String) {
        keys.insert(key)
    }

    /// Returns an error string when the log could not be written.
    @discardableResult
    func save() -> String? {
        guard isReadable else { return loadError }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a crash or unplug mid-write would otherwise truncate the
            // file, and a truncated file won't parse on next launch.
            try JSONEncoder().encode(keys).write(to: fileURL, options: .atomic)
            return nil
        } catch {
            return "Could not save recovery history: \(error.localizedDescription)"
        }
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
    /// True when an earlier result in this scan had the same fingerprint.
    /// A heuristic, not proof — see RecoveryScanner.fingerprint.
    var isDuplicate = false
    /// Prefix-and-length hash, kept so a manifest can re-verify this data is
    /// still on the drive before recovering from recorded offsets.
    var fingerprint: String?

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

/// EXIF/TIFF/GPS fields read from a carved image. Metadata sits near the start
/// of the file, so a truncated carve whose pixels won't render often still has
/// readable metadata. Every field is optional: absent means the file didn't
/// carry it, and the row is hidden rather than shown empty.
struct ImageMetadata: Sendable, Equatable {
    var pixelSize: String?
    var captureDate: String?
    var camera: String?
    var lens: String?
    var exposure: String?
    var coordinate: Coordinate?

    var isEmpty: Bool {
        pixelSize == nil && captureDate == nil && camera == nil
            && lens == nil && exposure == nil && coordinate == nil
    }

    struct Coordinate: Sendable, Equatable {
        let latitude: Double
        let longitude: Double

        /// Signed decimal degrees, formatted with the hemisphere spelled out.
        var label: String {
            let ns = latitude >= 0 ? "N" : "S"
            let ew = longitude >= 0 ? "E" : "W"
            return String(format: "%.5f° %@, %.5f° %@", abs(latitude), ns, abs(longitude), ew)
        }

        /// Apple Maps pin. ponytail: coordinates only — reverse geocoding to a
        /// place name needs CLGeocoder and a network round-trip per file.
        var mapsURL: URL? {
            URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(latitude),\(longitude)")
        }
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

    /// Bytes read over bytes to read. Rough by nature: free space is scanned in
    /// regions of uneven size and a dense region yields more candidates per
    /// byte, so the rate is not constant.
    var percentLabel: String? {
        guard totalBytes > 0 else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Scanned and total as sizes, e.g. "412.7 GB of 991 GB".
    var byteLabel: String? {
        guard totalBytes > 0 else { return nil }
        let done = ByteCountFormatter.string(fromByteCount: Int64(bytesScanned), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        return "\(done) of \(total)"
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
