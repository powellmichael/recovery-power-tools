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
        let bytesRead = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress, raw.count, off_t(start))
        }
        guard bytesRead >= 0 else {
            throw RecoveryError.readFailed(displayName, offset)
        }
        let available = UInt64(bytesRead)
        let skip = offset - start
        guard available > skip else { return Data() }
        let take = min(want, available - skip)
        return buffer.subdata(in: Int(skip)..<Int(skip + take))
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
