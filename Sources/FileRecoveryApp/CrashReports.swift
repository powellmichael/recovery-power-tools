import AppKit
import Foundation

/// Opt-in crash reporting with no server: macOS already writes a report for
/// every crash, so the app only has to find its own, show it, and let the
/// user send it. Nothing is collected or sent unless the user turned this on
/// and then chooses Send for that report.
///
/// ponytail: sends by email through the user's own mail app. A reporting
/// service is the upgrade once there are enough users for the volume to
/// matter; this needs no account, no SDK and no privacy policy clause.
enum CrashReports {
    static let enabledKey = "crashReportingEnabled"
    static let checkedKey = "crashReportsCheckedAt"

    static var systemFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Where reports are sent, when the build names an address.
    static var supportEmail: String? {
        (Bundle.main.object(forInfoDictionaryKey: "RPTSupportEmail") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// This app's crash reports written after `date`, newest first.
    /// macOS names them "<process>-<date>.ips" (".crash" on older systems).
    static func reports(
        in folder: URL = systemFolder,
        processName: String = ProcessInfo.processInfo.processName,
        after date: Date
    ) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(processName + "-") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let written = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      written > date else { return nil }
                return (url, written)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Reports since the last check, if the user has opted in. Each report is
    /// offered once: the check time moves forward whenever this is called.
    static func pending(defaults: UserDefaults = .standard, folder: URL = systemFolder, now: Date = Date()) -> [URL] {
        guard defaults.bool(forKey: enabledKey) else { return [] }
        let last = defaults.double(forKey: checkedKey)
        defaults.set(now.timeIntervalSince1970, forKey: checkedKey)
        // First check after opting in: crashes from before the user agreed
        // are not offered.
        guard last > 0 else { return [] }
        return reports(in: folder, after: Date(timeIntervalSince1970: last))
    }

    /// Opens a new message in the user's mail app with the reports attached.
    /// Returns false when there is no address or no mail app to do it.
    @MainActor
    static func compose(_ reports: [URL]) -> Bool {
        guard let address = supportEmail, let service = NSSharingService(named: .composeEmail) else { return false }
        service.recipients = [address]
        service.subject = "Recovery Power Tools crash report"
        let note = "Recovery Power Tools quit unexpectedly. The report is attached.\n\nWhat I was doing at the time:\n"
        let items: [Any] = [note] + reports
        guard service.canPerform(withItems: items) else { return false }
        service.perform(withItems: items)
        return true
    }
}
