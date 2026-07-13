import Foundation

enum MediaKind: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case heic = "HEIC"
    case video = "Video"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .video: "mov"
        }
    }
}

struct RecoveredItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let kind: MediaKind
    let sourceURL: URL
    let byteOffset: UInt64
    let byteLength: UInt64
    var recoveredURL: URL?

    var displayName: String {
        "\(kind.rawValue.lowercased())-\(String(byteOffset, radix: 16)).\(kind.fileExtension)"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteLength), countStyle: .file)
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
