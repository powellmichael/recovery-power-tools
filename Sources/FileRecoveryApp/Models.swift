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
}

struct RecoveredItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let kind: MediaKind
    let source: ScanSource
    let byteOffset: UInt64
    let byteLength: UInt64
    let fileExtension: String
    let originalFilename: String?
    var recoveredURL: URL?
    var recoveryError: String?

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
    case recovering
    case finished
    case failed(String)
}
