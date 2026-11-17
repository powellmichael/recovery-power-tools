import Foundation
import Testing
@testable import FileRecoveryApp

@Suite struct LaunchReadinessTests {
    private func write(_ name: String, in folder: URL, modified: Date) throws {
        let url = folder.appendingPathComponent(name)
        try Data("report".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func crashReportsAreOfferedOnlyAfterOptInAndOnlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "crash-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let process = ProcessInfo.processInfo.processName
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try write("\(process)-old.ips", in: folder, modified: start.addingTimeInterval(-100))

        // Not opted in: nothing, however many reports exist.
        #expect(CrashReports.pending(defaults: defaults, folder: folder, now: start).isEmpty)
        #expect(defaults.double(forKey: CrashReports.checkedKey) == 0)

        // Opting in does not dig up crashes from before.
        defaults.set(true, forKey: CrashReports.enabledKey)
        #expect(CrashReports.pending(defaults: defaults, folder: folder, now: start).isEmpty)

        try write("\(process)-new.ips", in: folder, modified: start.addingTimeInterval(50))
        try write("\(process)-newer.crash", in: folder, modified: start.addingTimeInterval(60))
        try write("SomeOtherApp-new.ips", in: folder, modified: start.addingTimeInterval(50))
        try write("\(process)-notes.txt", in: folder, modified: start.addingTimeInterval(50))

        let found = CrashReports.pending(defaults: defaults, folder: folder, now: start.addingTimeInterval(100))
        #expect(found.map(\.lastPathComponent) == ["\(process)-newer.crash", "\(process)-new.ips"])

        // Offered once.
        #expect(CrashReports.pending(defaults: defaults, folder: folder, now: start.addingTimeInterval(200)).isEmpty)
    }

    @Test func helpCoversEveryToolAndHasNoEmptyPages() {
        let ids = HelpContent.topics.map(\.id)
        #expect(Set(ids).count == ids.count)
        for required in ["start", "recover", "image", "copy", "duplicates", "erase", HelpContent.cannotFindID] {
            #expect(ids.contains(required))
        }
        for topic in HelpContent.topics {
            #expect(!topic.sections.isEmpty)
            for section in topic.sections {
                #expect(!(section.paragraphs.isEmpty && section.bullets.isEmpty), "\(topic.id) has an empty section")
            }
        }
        #expect(HelpContent.topic("no-such-page").id == "start")
    }
}
