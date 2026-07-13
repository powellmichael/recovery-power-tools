import Darwin
import Foundation

struct ExternalDevice: Identifiable, Hashable, Sendable {
    /// BSD identifier, e.g. "disk4" or "disk4s1".
    let identifier: String
    let volumeName: String?
    let size: UInt64
    let isWholeDisk: Bool

    var id: String { identifier }
    var rawDevicePath: String { "/dev/r\(identifier)" }

    /// "disk4s2" -> "disk4"
    var wholeDiskIdentifier: String {
        guard identifier.hasPrefix("disk") else { return identifier }
        let digits = identifier.dropFirst(4).prefix(while: \.isNumber)
        return "disk\(digits)"
    }

    var displayName: String {
        let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let name = volumeName ?? (isWholeDisk ? "Entire Disk" : "Untitled")
        return "\(name) (\(identifier), \(sizeLabel))"
    }
}

enum DeviceDiscovery {
    /// Lists external physical disks and their partitions via diskutil.
    static func externalDevices() -> [ExternalDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["list", "-plist", "external", "physical"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var devices: [ExternalDevice] = []
        for disk in disks {
            guard let diskID = disk["DeviceIdentifier"] as? String else { continue }
            let diskSize = (disk["Size"] as? NSNumber)?.uint64Value ?? 0
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            for partition in partitions {
                guard let partID = partition["DeviceIdentifier"] as? String else { continue }
                let partSize = (partition["Size"] as? NSNumber)?.uint64Value ?? 0
                let name = partition["VolumeName"] as? String ?? partition["Content"] as? String
                devices.append(ExternalDevice(identifier: partID, volumeName: name, size: partSize, isWholeDisk: false))
            }
            devices.append(ExternalDevice(identifier: diskID, volumeName: nil, size: diskSize, isWholeDisk: true))
        }
        return devices
    }

    /// BSD partition name backing the volume that contains `path`, e.g. "disk4s1".
    static func bsdName(forPath path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mountedFrom = withUnsafeBytes(of: &fs.f_mntfromname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        var name = mountedFrom.hasPrefix("/dev/") ? String(mountedFrom.dropFirst(5)) : mountedFrom
        if name.hasPrefix("rdisk") { name.removeFirst() }
        return name.hasPrefix("disk") ? name : nil
    }

    /// True when `destination` lives on the same physical disk as `device` —
    /// recovering onto the disk being recovered from would overwrite deleted data.
    static func destination(_ destination: URL, isOnSameDiskAs device: ExternalDevice) -> Bool {
        guard let name = bsdName(forPath: destination.path) else { return false }
        let digits = name.dropFirst(4).prefix(while: \.isNumber)
        return "disk\(digits)" == device.wholeDiskIdentifier
    }

    /// The external device whose volume contains `url`, if any.
    static func externalDevice(containing url: URL, in devices: [ExternalDevice]) -> ExternalDevice? {
        guard let name = bsdName(forPath: url.path) else { return nil }
        return devices.first { $0.identifier == name }
            ?? devices.first { !$0.isWholeDisk && $0.wholeDiskIdentifier == name }
    }
}
