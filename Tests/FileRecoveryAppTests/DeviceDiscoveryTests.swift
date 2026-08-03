import Testing
@testable import FileRecoveryApp

@Suite struct DevicePresentationTests {
    @Test func hidesTechnicalSystemPartitions() {
        let efi = ExternalDevice(
            identifier: "disk4s1",
            volumeName: "EFI",
            size: 209_715_200,
            isWholeDisk: false,
            contentType: "EFI"
        )
        let recovery = ExternalDevice(
            identifier: "disk4s3",
            volumeName: "Recovery",
            size: 1_073_741_824,
            isWholeDisk: false,
            contentType: "Apple_APFS_Recovery"
        )
        let data = ExternalDevice(
            identifier: "disk4s2",
            volumeName: "Photos",
            size: 500_000_000_000,
            isWholeDisk: false,
            filesystemName: "ExFAT"
        )

        #expect(efi.isSystemPartition)
        #expect(recovery.isSystemPartition)
        #expect(!data.isSystemPartition)
    }

    @Test func labelsSupportedAndLimitedFilesystems() {
        let exfat = ExternalDevice(
            identifier: "disk5s1",
            volumeName: "Archive",
            size: 1,
            isWholeDisk: false,
            filesystemName: "ExFAT"
        )
        let ntfs = ExternalDevice(
            identifier: "disk6s1",
            volumeName: "Windows",
            size: 1,
            isWholeDisk: false,
            filesystemName: "NTFS"
        )
        let apfs = ExternalDevice(
            identifier: "disk7s2",
            volumeName: nil,
            size: 1,
            isWholeDisk: false,
            contentType: "Apple_APFS"
        )

        #expect(exfat.recoveryCompatibility == .fullySupported)
        #expect(ntfs.recoveryCompatibility == .fullySupported)
        #expect(apfs.recoveryCompatibility == .limited)
        #expect(apfs.filesystemLabel == "APFS")
    }

    @Test func suppliesFriendlyFallbackNames() {
        let apfs = ExternalDevice(
            identifier: "disk4s2",
            volumeName: nil,
            size: 1,
            isWholeDisk: false,
            contentType: "Apple_APFS"
        )
        let physical = ExternalDevice(
            identifier: "disk4",
            volumeName: nil,
            size: 1,
            isWholeDisk: true,
            physicalName: "Photo Archive SSD"
        )

        #expect(apfs.userFacingName == "APFS Container")
        #expect(physical.userFacingName == "Photo Archive SSD")
        #expect(apfs.wholeDiskIdentifier == physical.identifier)
    }
}
