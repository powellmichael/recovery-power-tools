import Darwin
import Foundation

enum RecoveryCompatibility: Equatable, Sendable {
    case fullySupported
    case limited
    case unknown
}

struct ExternalDevice: Identifiable, Hashable, Sendable {
    /// BSD identifier, e.g. "disk4" or "disk4s1".
    let identifier: String
    let volumeName: String?
    let size: UInt64
    let isWholeDisk: Bool
    var contentType: String? = nil
    var filesystemName: String? = nil
    var mountPoint: String? = nil
    var busProtocol: String? = nil
    var physicalName: String? = nil

    var id: String { identifier }
    var rawDevicePath: String { "/dev/r\(identifier)" }

    /// "disk4s2" -> "disk4"
    var wholeDiskIdentifier: String {
        guard identifier.hasPrefix("disk") else { return identifier }
        let digits = identifier.dropFirst(4).prefix(while: \.isNumber)
        return "disk\(digits)"
    }

    var userFacingName: String {
        if let volumeName, !volumeName.isEmpty { return volumeName }
        if isWholeDisk { return physicalName ?? "Physical Disk" }
        switch contentType?.lowercased() {
        case "apple_apfs": return "APFS Container"
        case "microsoft basic data": return "Untitled Windows Volume"
        default: return "Untitled Volume"
        }
    }

    var filesystemLabel: String {
        if let filesystemName, !filesystemName.isEmpty { return filesystemName }
        switch contentType?.lowercased() {
        case "apple_apfs": return "APFS"
        case "microsoft basic data": return "Windows volume"
        case "efi": return "EFI"
        default: return "Unknown filesystem"
        }
    }

    var recoveryCompatibility: RecoveryCompatibility {
        let value = (filesystemName ?? contentType ?? "").lowercased()
        if value.contains("exfat") || value.contains("ntfs") || value.contains("fat32")
            || value.contains("ms-dos fat32") {
            return .fullySupported
        }
        if value.contains("apfs") { return .limited }
        return .unknown
    }

    var isSystemPartition: Bool {
        guard !isWholeDisk else { return false }
        let value = (contentType ?? volumeName ?? "").lowercased()
        return value == "efi" || value.contains("apple_boot") || value.contains("recovery")
    }

    var displayName: String {
        let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "\(userFacingName) (\(identifier), \(sizeLabel))"
    }
}

enum DeviceDiscovery {
    private struct DeviceDetails {
        var volumeName: String?
        var filesystemName: String?
        var mountPoint: String?
        var busProtocol: String?
        var physicalName: String?
    }

    /// Lists external physical disks and their partitions via diskutil.
    static func externalDevices() -> [ExternalDevice] {
        guard let plist = diskutilPlist(["list", "-plist", "external", "physical"]),
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var devices: [ExternalDevice] = []
        for disk in disks {
            guard let diskID = disk["DeviceIdentifier"] as? String else { continue }
            let diskSize = (disk["Size"] as? NSNumber)?.uint64Value ?? 0
            let wholeDetails = details(for: diskID)
            let physicalName = wholeDetails.physicalName
            let partitions = disk["Partitions"] as? [[String: Any]] ?? []
            for partition in partitions {
                guard let partID = partition["DeviceIdentifier"] as? String else { continue }
                let partSize = (partition["Size"] as? NSNumber)?.uint64Value ?? 0
                let content = partition["Content"] as? String
                let listedName = partition["VolumeName"] as? String
                // EFI and recovery partitions are implementation details, not
                // useful recovery targets. Never put them in the user chooser.
                let probe = ExternalDevice(
                    identifier: partID,
                    volumeName: listedName,
                    size: partSize,
                    isWholeDisk: false,
                    contentType: content
                )
                guard !probe.isSystemPartition else { continue }

                let partDetails = details(for: partID)
                devices.append(ExternalDevice(
                    identifier: partID,
                    volumeName: partDetails.volumeName ?? listedName,
                    size: partSize,
                    isWholeDisk: false,
                    contentType: content,
                    filesystemName: partDetails.filesystemName,
                    mountPoint: partDetails.mountPoint,
                    busProtocol: partDetails.busProtocol ?? wholeDetails.busProtocol,
                    physicalName: physicalName
                ))
            }
            devices.append(ExternalDevice(
                identifier: diskID,
                volumeName: nil,
                size: diskSize,
                isWholeDisk: true,
                contentType: disk["Content"] as? String,
                busProtocol: wholeDetails.busProtocol,
                physicalName: physicalName
            ))
        }
        return devices
    }

    private static func details(for identifier: String) -> DeviceDetails {
        guard let plist = diskutilPlist(["info", "-plist", "/dev/\(identifier)"]) else {
            return DeviceDetails()
        }
        func nonempty(_ key: String) -> String? {
            guard let value = plist[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let registryName = nonempty("IORegistryEntryName")?.replacingOccurrences(
            of: #"\s+Media$"#,
            with: "",
            options: .regularExpression
        )
        return DeviceDetails(
            volumeName: nonempty("VolumeName"),
            filesystemName: nonempty("FilesystemUserVisibleName") ?? nonempty("FilesystemName"),
            mountPoint: nonempty("MountPoint"),
            busProtocol: nonempty("BusProtocol"),
            physicalName: registryName ?? nonempty("MediaName")
        )
    }

    static func diskutilPlist(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Unmounts a volume, or every volume on a whole disk, without ejecting it,
    /// so the raw device stays available to scan. Never forced: if a file on
    /// it is open, diskutil refuses and its message is returned.
    /// Returns nil on success.
    static func unmount(_ device: ExternalDevice) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = [device.isWholeDisk ? "unmountDisk" : "unmount", "/dev/\(device.identifier)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "Could not run diskutil: \(error.localizedDescription)"
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return output.isEmpty ? "The volume could not be unmounted." : output
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
