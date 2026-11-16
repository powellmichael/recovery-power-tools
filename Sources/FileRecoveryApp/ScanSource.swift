import Darwin
import Foundation

/// A read-only byte source: a regular file, or a raw device opened via authopen.
/// Reads use pread (stateless, thread-safe) and are block-aligned for raw devices.
final class ScanSource: @unchecked Sendable {
    let size: UInt64
    let displayName: String
    let fileURL: URL?
    let devicePath: String?
    private let fd: Int32
    private let alignment: UInt64

    /// Start offsets of blocks that could not be read and were zero-filled.
    /// A set, because the same bad block is hit again by length parsers,
    /// fingerprinting and recovery, and must only be counted once.
    private let badBlockLock = NSLock()
    private var badBlocks: Set<UInt64> = []
    /// Test hook: reads touching these byte ranges fail with EIO, as a bad
    /// sector does. Set before the source is used.
    var simulatedBadRanges: [Range<UInt64>] = []

    /// Smallest unit salvaged on its own. Raw devices must read whole blocks;
    /// files have no such rule, so use the common 4 KB sector.
    private var salvageUnit: UInt64 { alignment > 1 ? alignment : 4096 }
    private static let salvagePiece: UInt64 = 64 * 1024

    /// Bytes that could not be read so far and were replaced with zeros.
    var unreadableBytes: UInt64 {
        badBlockLock.withLock { UInt64(badBlocks.count) } * salvageUnit
    }

    /// True when any part of `range` was zero-filled because it was unreadable.
    func hasUnreadableData(in range: Range<UInt64>) -> Bool {
        let unit = salvageUnit
        return badBlockLock.withLock {
            // Empty on a healthy drive, so this is one check per call there.
            !badBlocks.isEmpty && badBlocks.contains { $0 < range.upperBound && $0 + unit > range.lowerBound }
        }
    }

    init(fileURL: URL) throws {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw RecoveryError.cannotOpen(fileURL.path) }
        var info = stat()
        fstat(fd, &info)
        self.fd = fd
        self.size = UInt64(max(0, info.st_size))
        self.displayName = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.devicePath = nil
        self.alignment = 1
    }

    init(devicePath: String, displayName: String) throws {
        let fd = try Self.openWithAuthorization(devicePath)
        // DKIOCGETBLOCKSIZE / DKIOCGETBLOCKCOUNT from <sys/disk.h>
        var blockSize: UInt32 = 0
        var blockCount: UInt64 = 0
        let sizeOK = withUnsafeMutablePointer(to: &blockSize) { ioctl(fd, 0x40046418, $0) == 0 }
        let countOK = withUnsafeMutablePointer(to: &blockCount) { ioctl(fd, 0x40086419, $0) == 0 }
        guard sizeOK, countOK, blockSize > 0, blockCount > 0 else {
            close(fd)
            throw RecoveryError.cannotOpen(devicePath)
        }
        self.fd = fd
        self.size = UInt64(blockSize) * blockCount
        self.displayName = displayName
        self.fileURL = nil
        self.devicePath = devicePath
        self.alignment = UInt64(blockSize)
    }

    deinit {
        close(fd)
    }

    /// Reads up to `count` bytes at `offset`; short reads only at end of source.
    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < size else { return Data() }
        let want = min(UInt64(count), size - offset)
        let start = (offset / alignment) * alignment
        let end = min(size, ((offset + want + alignment - 1) / alignment) * alignment)
        var buffer = Data(count: Int(end - start))
        var bytesRead = buffer.withUnsafeMutableBytes { raw in
            rawRead(raw.baseAddress, raw.count, at: start)
        }
        if bytesRead < 0 {
            // EIO is a bad sector: salvage what surrounds it. Anything else
            // (drive unplugged, fd revoked) still ends the scan.
            guard errno == EIO else { throw RecoveryError.readFailed(displayName, offset) }
            bytesRead = try buffer.withUnsafeMutableBytes { raw in
                try salvage(into: raw, at: start, failedAt: offset)
            }
        }
        let available = UInt64(bytesRead)
        let skip = offset - start
        guard available > skip else { return Data() }
        let take = min(want, available - skip)
        // Block-aligned reads — every 4 MB scan chunk, and every read of a
        // regular file — need nothing trimmed from the front, so hand the
        // buffer back instead of paying a full copy through subdata.
        guard skip > 0 else {
            if take < UInt64(buffer.count) {
                buffer.removeSubrange(Int(take)..<buffer.count)
            }
            return buffer
        }
        return buffer.subdata(in: Int(skip)..<Int(skip + take))
    }

    private func rawRead(_ pointer: UnsafeMutableRawPointer?, _ count: Int, at offset: UInt64) -> Int {
        if !simulatedBadRanges.isEmpty {
            let span = offset..<(offset + UInt64(count))
            if simulatedBadRanges.contains(where: { $0.overlaps(span) }) {
                errno = EIO
                return -1
            }
        }
        return pread(fd, pointer, count, off_t(offset))
    }

    /// Re-reads a failed range in 64 KB pieces, then block by block inside any
    /// piece that still fails. Unreadable blocks become zeros and are recorded,
    /// so one bad sector costs one block instead of the whole scan.
    /// Returns how many bytes of `raw` are valid (short only at end of source).
    ///
    /// ponytail: a piece whose first and last blocks both fail is written off
    /// whole without probing the middle — a failing read can take seconds, and
    /// a dead stretch of disk would otherwise stall the scan for hours. That
    /// gives up at most 64 KB of readable data inside a bad patch. Probe every
    /// block (as ddrescue's scraping pass does) if that ever matters.
    private func salvage(into raw: UnsafeMutableRawBufferPointer, at start: UInt64, failedAt offset: UInt64) throws -> Int {
        let total = raw.count
        var bad: [UInt64] = []
        defer {
            if !bad.isEmpty { badBlockLock.withLock { badBlocks.formUnion(bad) } }
        }

        // Blocks and pieces sit on a fixed grid of absolute offsets. Files are
        // read at arbitrary offsets, and blocks cut relative to each read would
        // record one bad sector as several different "blocks".
        let unit64 = salvageUnit
        func gridEnd(_ position: Int, _ grid: UInt64, limit: Int) -> Int {
            let absolute = start + UInt64(position)
            return min(limit, position + Int((absolute / grid + 1) * grid - absolute))
        }

        /// Reads the block starting at `position`; zero-fills and records it
        /// when unreadable.
        func readBlock(_ position: Int, end: Int, probe: Bool = true) throws -> Bool {
            if probe {
                let got = rawRead(raw.baseAddress! + position, end - position, at: start + UInt64(position))
                if got >= 0 { return true }
                guard errno == EIO else { throw RecoveryError.readFailed(displayName, offset) }
            }
            memset(raw.baseAddress! + position, 0, end - position)
            bad.append((start + UInt64(position)) / unit64 * unit64)
            return false
        }

        var position = 0
        while position < total {
            let pieceEnd = gridEnd(position, Self.salvagePiece, limit: total)
            let got = rawRead(raw.baseAddress! + position, pieceEnd - position, at: start + UInt64(position))
            if got >= 0 {
                if got < pieceEnd - position { return position + got }
            } else {
                guard errno == EIO else { throw RecoveryError.readFailed(displayName, offset) }
                var blocks: [Range<Int>] = []
                var cursor = position
                while cursor < pieceEnd {
                    let end = gridEnd(cursor, unit64, limit: pieceEnd)
                    blocks.append(cursor..<end)
                    cursor = end
                }
                let firstOK = try readBlock(blocks[0].lowerBound, end: blocks[0].upperBound)
                let last = blocks[blocks.count - 1]
                let lastOK = blocks.count > 1 ? try readBlock(last.lowerBound, end: last.upperBound) : firstOK
                for block in blocks.dropFirst().dropLast() {
                    _ = try readBlock(block.lowerBound, end: block.upperBound, probe: firstOK || lastOK)
                }
            }
            position = pieceEnd
        }
        return total
    }

    // MARK: - authopen

    /// Opens a raw device read-only via /usr/libexec/authopen, which shows the
    /// standard macOS authorization prompt and passes back the fd over a socket.
    private static func openWithAuthorization(_ path: String) throws -> Int32 {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw RecoveryError.cannotOpen(path)
        }
        let receiveSocket = sockets[0]
        let sendSocket = sockets[1]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = ["-stdoutpipe", path]
        process.standardOutput = FileHandle(fileDescriptor: sendSocket, closeOnDealloc: false)
        do {
            try process.run()
        } catch {
            close(receiveSocket)
            close(sendSocket)
            throw RecoveryError.cannotOpen(path)
        }
        close(sendSocket)

        let fd = receiveFileDescriptor(on: receiveSocket)
        close(receiveSocket)
        process.waitUntilExit()

        guard let fd else { throw RecoveryError.deviceAccessDenied(path) }
        return fd
    }

    private static func receiveFileDescriptor(on socket: Int32) -> Int32? {
        var dataBuffer = [UInt8](repeating: 0, count: 32)
        // cmsghdr (12 bytes) + fd payload; sized generously.
        var controlBuffer = [UInt8](repeating: 0, count: 64)
        var receivedFD: Int32?

        dataBuffer.withUnsafeMutableBytes { dataPtr in
            controlBuffer.withUnsafeMutableBytes { controlPtr in
                var iov = iovec(iov_base: dataPtr.baseAddress, iov_len: dataPtr.count)
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    var message = msghdr()
                    message.msg_iov = iovPtr
                    message.msg_iovlen = 1
                    message.msg_control = controlPtr.baseAddress
                    message.msg_controllen = socklen_t(controlPtr.count)

                    let received = recvmsg(socket, &message, 0)
                    guard received >= 0, message.msg_controllen >= 16 else { return }
                    let header = controlPtr.load(as: cmsghdr.self)
                    guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return }
                    // CMSG_DATA sits right after the 12-byte header on Darwin.
                    receivedFD = controlPtr.load(fromByteOffset: 12, as: Int32.self)
                }
            }
        }
        return receivedFD
    }
}

extension ScanSource: Hashable {
    static func == (lhs: ScanSource, rhs: ScanSource) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
