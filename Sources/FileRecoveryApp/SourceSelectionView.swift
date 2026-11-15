import AppKit
import SwiftUI

private struct PhysicalDriveGroup: Identifiable {
    let id: String
    let name: String
    let size: UInt64
    let busProtocol: String?
    let volumes: [ExternalDevice]
}

/// The app's first-run surface. Recovery settings stay out of the way until
/// the user has made the one decision that gives them context: what to scan.
struct SourceSelectionView: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @Binding var appearanceRaw: String
    @State private var showsAdvancedDevices = false

    private let columns = [
        GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 16)
    ]

    private var driveGroups: [PhysicalDriveGroup] {
        let wholeDisks = Dictionary(
            uniqueKeysWithValues: viewModel.externalDevices.filter(\.isWholeDisk).map { ($0.identifier, $0) }
        )
        let volumes = viewModel.externalDevices.filter { !$0.isWholeDisk && !$0.isSystemPartition }
        return Dictionary(grouping: volumes, by: \.wholeDiskIdentifier).map { identifier, volumes in
            let disk = wholeDisks[identifier]
            return PhysicalDriveGroup(
                id: identifier,
                name: disk?.physicalName ?? volumes.first?.physicalName ?? "External Drive",
                size: disk?.size ?? volumes.map(\.size).max() ?? 0,
                busProtocol: disk?.busProtocol ?? volumes.first?.busProtocol,
                volumes: volumes.sorted {
                    $0.userFacingName.localizedStandardCompare($1.userFacingName) == .orderedAscending
                }
            )
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var advancedDevices: [ExternalDevice] {
        viewModel.externalDevices.filter(\.isWholeDisk).sorted {
            $0.userFacingName.localizedStandardCompare($1.userFacingName) == .orderedAscending
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            Circle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: 560, height: 560)
                .blur(radius: 100)
                .offset(x: 420, y: -300)
                .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    hero
                    sourceSection

                    if let warning = viewModel.logWarning {
                        Label(warning, systemImage: "clock.badge.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    safetyStrip
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, 48)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshingDevices)
                .help("Look for newly connected drives")

                Menu {
                    ForEach(AppearancePreference.allCases) { preference in
                        Button {
                            appearanceRaw = preference.rawValue
                        } label: {
                            if preference.rawValue == appearanceRaw {
                                Label(preference.label, systemImage: "checkmark")
                            } else {
                                Text(preference.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: (AppearancePreference(rawValue: appearanceRaw) ?? .system).systemImage)
                }
                .help("Appearance")
            }
        }
        .onAppear {
            if viewModel.externalDevices.isEmpty {
                viewModel.refreshDevices()
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 94, height: 94)
                    .shadow(color: Color.accentColor.opacity(0.25), radius: 18, y: 8)

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 35, weight: .semibold))
                    .foregroundStyle(.white)

                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 31, y: 29)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Recover lost files with confidence")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Choose a drive to begin a safe, read-only scan for deleted photos, videos, and archives.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 700, alignment: .leading)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a source")
                        .font(.title2.weight(.semibold))
                    Text("External drives and their volumes appear here automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.isRefreshingDevices {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for drives…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if driveGroups.isEmpty, !viewModel.isRefreshingDevices {
                noDrivesCard
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(driveGroups) { group in
                        PhysicalDriveCard(group: group, chooseDevice: viewModel.chooseDevice)
                    }
                }
            }

            if !advancedDevices.isEmpty {
                advancedSection
            }

            Button {
                viewModel.chooseSource()
            } label: {
                Label("Open a disk image, file, or folder…", systemImage: "folder.badge.gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Disk images can contain deleted files; folders contain existing files only")
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showsAdvancedDevices) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Whole-disk scans bypass the normal volume choice. Use one only when a volume is missing or its partition information is damaged; results may include live files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(advancedDevices) { device in
                    AdvancedDeviceButton(device: device) {
                        viewModel.chooseDevice(device)
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Label("Advanced devices", systemImage: "externaldrive.badge.plus")
                .font(.callout.weight(.medium))
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var noDrivesCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(advancedDevices.isEmpty ? "No external drives found" : "No usable volumes found")
                .font(.headline)
            Text(advancedDevices.isEmpty
                 ? "Connect a drive or memory card, then refresh. You can also open a disk image below."
                 : "This drive has no normal data volumes. Open Advanced Devices below if you need to scan the entire physical disk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Refresh") {
                viewModel.refreshDevices()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var safetyStrip: some View {
        HStack(spacing: 28) {
            SafetyBadge(icon: "lock.shield.fill", text: "Read-only scanning")
            SafetyBadge(icon: "checkmark.circle.fill", text: "Source stays untouched")
            SafetyBadge(icon: "hand.raised.fill", text: "Recovery happens only when you approve")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }
}

private struct PhysicalDriveCard: View {
    let group: PhysicalDriveGroup
    let chooseDevice: (ExternalDevice) -> Void
    @State private var isHovering = false

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(group.size), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(.tint)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let bus = group.busProtocol {
                            Text(bus)
                            Text("•")
                        }
                        Text(sizeLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(18)

            Divider()
                .padding(.horizontal, 18)

            VStack(spacing: 0) {
                ForEach(Array(group.volumes.enumerated()), id: \.element.id) { index, device in
                    VolumeSelectionRow(device: device) {
                        chooseDevice(device)
                    }
                    if index < group.volumes.count - 1 {
                        Divider()
                            .padding(.leading, 18)
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isHovering ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.09),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(isHovering ? 0.09 : 0.04), radius: isHovering ? 12 : 5, y: 3)
    }
}

private struct VolumeSelectionRow: View {
    let device: ExternalDevice
    let action: () -> Void
    @State private var isHovering = false

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(device.size), countStyle: .file)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.userFacingName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(device.filesystemLabel)
                        Text("•")
                        Text(sizeLabel)
                        CompatibilityBadge(compatibility: device.recoveryCompatibility)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
            .background(isHovering ? Color.accentColor.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("Scan \(device.userFacingName), \(device.filesystemLabel), \(sizeLabel)")
        .help("Select \(device.userFacingName) as the scan source (\(device.identifier))")
    }
}

private struct CompatibilityBadge: View {
    let compatibility: RecoveryCompatibility

    private var label: String {
        switch compatibility {
        case .fullySupported: "Fully supported"
        case .limited: "Limited recovery"
        case .unknown: "Compatibility unknown"
        }
    }

    private var tint: Color {
        switch compatibility {
        case .fullySupported: .green
        case .limited: .orange
        case .unknown: .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

private struct AdvancedDeviceButton: View {
    let device: ExternalDevice
    let action: () -> Void

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(device.size), countStyle: .file)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.userFacingName)
                        .font(.callout.weight(.medium))
                    Text("Entire physical disk • \(sizeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .help("Scan the entire device (\(device.identifier))")
    }
}

private struct SafetyBadge: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.green)
        }
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity)
    }
}

private struct SourceSelectionViewPreviews: PreviewProvider {
    static var previews: some View {
        let viewModel = RecoveryViewModel(
            recoveryLogURL: URL(fileURLWithPath: "/tmp/file-recovery-preview/recovered.json"),
            reviewLogURL: URL(fileURLWithPath: "/tmp/file-recovery-preview/review.json")
        )
        viewModel.externalDevices = [
            ExternalDevice(
                identifier: "disk4s2",
                volumeName: nil,
                size: 1_000_204_886_016,
                isWholeDisk: false,
                contentType: "Apple_APFS",
                busProtocol: "USB",
                physicalName: "Photo Archive SSD"
            ),
            ExternalDevice(
                identifier: "disk5s2",
                volumeName: "Camera Card",
                size: 128_043_712_512,
                isWholeDisk: false,
                contentType: "Microsoft Basic Data",
                filesystemName: "ExFAT",
                busProtocol: "USB",
                physicalName: "Camera Card Reader"
            ),
            ExternalDevice(
                identifier: "disk4",
                volumeName: nil,
                size: 1_000_204_886_016,
                isWholeDisk: true,
                busProtocol: "USB",
                physicalName: "Photo Archive SSD"
            ),
            ExternalDevice(
                identifier: "disk5",
                volumeName: nil,
                size: 128_043_712_512,
                isWholeDisk: true,
                busProtocol: "USB",
                physicalName: "Camera Card Reader"
            )
        ]
        return SourceSelectionView(viewModel: viewModel, appearanceRaw: .constant("system"))
            .frame(width: 1180, height: 760)
    }
}
