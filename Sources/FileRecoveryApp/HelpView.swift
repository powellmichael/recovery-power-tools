import SwiftUI

/// The Help window: topics on the left, the chosen page on the right.
struct HelpView: View {
    @AppStorage("helpTopic") private var topicID = HelpContent.topics[0].id

    var body: some View {
        NavigationSplitView {
            List(HelpContent.topics, selection: Binding(get: { topicID }, set: { topicID = $0 ?? topicID })) { topic in
                Label(topic.title, systemImage: topic.systemImage)
                    .tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            HelpPage(topic: HelpContent.topic(topicID))
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct HelpPage: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(topic.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                ForEach(topic.sections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let heading = section.heading {
                            Text(heading)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(section.bullets, id: \.self) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(bullet)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 620, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A new page starts at its top, not where the last one was scrolled to.
        .id(topic.id)
    }
}

/// Opens the Help window at one page. Placed on each tool's first screen.
struct HelpLink: View {
    let topic: String
    var title = "Help"
    @Environment(\.openWindow) private var openWindow
    @AppStorage("helpTopic") private var topicID = HelpContent.topics[0].id

    var body: some View {
        Button {
            topicID = topic
            openWindow(id: "help")
        } label: {
            Label(title, systemImage: "questionmark.circle")
        }
        .buttonStyle(.link)
        .help("Open \(HelpContent.topic(topic).title) in Help")
    }
}

/// Shown once, on first launch: the few things that decide whether a
/// recovery works, said before the user has done anything to the drive.
struct WelcomeSheet: View {
    let dismiss: () -> Void
    @AppStorage(CrashReports.enabledKey) private var crashReports = false

    private let rules: [(String, String, String)] = [
        ("hand.raised.fill", "Stop using the drive", "Anything saved to it can overwrite the files you want back. Take a card out of the camera."),
        ("arrow.triangle.branch", "Recover to a different drive", "Saving recovered files onto the drive they came from destroys the others. The app will not let you."),
        ("externaldrive.badge.exclamationmark", "Copy a failing drive first", "If the drive clicks, drops out or is very slow, use Copy a Drive, then recover from the copy."),
        ("eye.fill", "Scanning is free and only reads", "Scan and preview before you pay. Nothing on the drive is changed. A licence is needed only to save recovered files."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you start")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Four things that decide whether your files come back.")
                    .foregroundStyle(.secondary)
            }

            ForEach(rules, id: \.1) { rule in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: rule.0)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.1)
                            .font(.headline)
                        Text(rule.2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            Toggle(isOn: $crashReports) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Offer to send a report if the app quits unexpectedly")
                    Text("Off unless you turn it on. You see each report and choose whether to send it. You can change this in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                HelpLink(topic: HelpContent.topics[0].id, title: "Read More in Help")
                Spacer()
                Button("Get Started", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}
