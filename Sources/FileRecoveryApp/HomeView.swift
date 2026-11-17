import SwiftUI

/// The launch screen: one card per tool. Tools that are not built yet are
/// shown as unavailable rather than hidden, so the product's shape is visible,
/// but they cannot be opened — a card that leads nowhere is worse than none.
struct HomeView: View {
    let openRecover: () -> Void
    let openDuplicates: () -> Void
    let openErase: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 18)]

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recovery Power Tools")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("What would you like to do?")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ToolCard(
                            title: "Recover Files",
                            detail: "Find deleted photos, videos and archives on an external drive or memory card.",
                            systemImage: "arrow.uturn.backward.circle.fill",
                            tint: .accentColor,
                            action: openRecover
                        )
                        ToolCard(
                            title: "Find Duplicates",
                            detail: "Find identical copies of files taking up space, and choose which to keep.",
                            systemImage: "square.on.square",
                            tint: .purple,
                            action: openDuplicates
                        )
                        ToolCard(
                            title: "Secure Erase",
                            detail: "Erase an external drive or card so its files cannot be recovered.",
                            systemImage: "lock.shield",
                            tint: .red,
                            action: openErase
                        )
                    }
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ToolCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    /// Nil marks a tool that is not available yet.
    let action: (() -> Void)?
    @State private var isHovering = false

    private var isAvailable: Bool { action != nil }

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isAvailable ? tint : .secondary)
                    .frame(width: 54, height: 54)
                    .background((isAvailable ? tint : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isAvailable {
                    Label("Open", systemImage: "arrow.right")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.tint)
                } else {
                    Text("Coming in a later version")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isHovering && isAvailable ? tint.opacity(0.45) : Color.primary.opacity(0.09)
                    )
            }
            .opacity(isAvailable ? 1 : 0.7)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isAvailable ? title : "\(title), not available yet")
        .accessibilityHint(detail)
    }
}
