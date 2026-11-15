import SwiftUI

/// Friendly presets cover normal scans; individual format toggles stay behind
/// Custom so new users do not have to understand twelve container formats.
struct MediaPresetSelector: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var showsCustomFormats = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    presetButton(.photos)
                    presetButton(.videos)
                }
                GridRow {
                    presetButton(.photosAndVideos)
                    presetButton(.everything)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if viewModel.selectedMediaPreset == .custom {
                        showsCustomFormats.toggle()
                    } else {
                        viewModel.selectMediaPreset(.custom)
                        showsCustomFormats = true
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: MediaPreset.custom.systemImage)
                    Text("Choose individual formats")
                    Spacer()
                    Image(systemName: showsCustomFormats && viewModel.selectedMediaPreset == .custom ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(viewModel.selectedMediaPreset == .custom ? .accentColor : nil)

            if viewModel.selectedMediaPreset == .custom, showsCustomFormats {
                Divider()
                MediaFilterList(viewModel: viewModel)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                if viewModel.selectedKinds.isEmpty {
                    Label("Choose at least one format to scan.", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Label {
                    Text(viewModel.selectedMediaPreset.detail)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: viewModel.selectedMediaPreset == .everything ? "clock" : "checkmark.circle.fill")
                        .foregroundStyle(viewModel.selectedMediaPreset == .everything ? .orange : .green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func presetButton(_ preset: MediaPreset) -> some View {
        let selected = viewModel.selectedMediaPreset == preset
        return Button {
            viewModel.selectMediaPreset(preset)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: preset.systemImage)
                    .font(.title3)
                Text(preset.label)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, 5)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.07))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.label) media preset")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(preset.detail)
    }
}

/// Media kinds grouped into collapsible categories. A category's own toggle
/// selects or clears every kind in it; the box is filled when only some are on.
struct MediaFilterList: View {
    @ObservedObject var viewModel: RecoveryViewModel
    @State private var expanded: Set<MediaCategory> = [.images]

    var body: some View {
        ForEach(MediaCategory.allCases) { category in
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(category) },
                set: { isOpen in
                    if isOpen { expanded.insert(category) } else { expanded.remove(category) }
                }
            )) {
                // Without an explicit leading alignment each row centres itself,
                // so "MP4 / MOV" and "AVI" start at different x positions and
                // the list reads as a staircase.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(category.kinds) { kind in
                        Toggle(kind.rawValue, isOn: Binding(
                            get: { viewModel.selectedKinds.contains(kind) },
                            set: { _ in viewModel.toggleKind(kind) }
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.leading, 2)
            } label: {
                Toggle(isOn: Binding(
                    get: { viewModel.allSelected(in: category) },
                    set: { viewModel.setKinds(in: category, on: $0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: categoryIcon(category))
                            .foregroundStyle(.secondary)
                        Text(category.rawValue)
                        if viewModel.someSelected(in: category), !viewModel.allSelected(in: category) {
                            Text("\(category.kinds.filter(viewModel.selectedKinds.contains).count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    private func categoryIcon(_ category: MediaCategory) -> String {
        switch category {
        case .images: "photo"
        case .video: "video"
        case .archives: "archivebox"
        }
    }
}

func icon(for kind: MediaKind) -> String {
    switch kind {
    case .jpeg, .png, .heic, .raw, .bmp: "photo"
    case .video, .avi, .wmv, .flv, .webm, .mpeg: "video"
    case .zip: "archivebox"
    }
}
