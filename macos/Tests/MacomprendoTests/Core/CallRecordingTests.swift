import Foundation
import Testing
@testable import Macomprendo

struct CallRecordingLayoutTests {
    let moscow = TimeZone(identifier: "Europe/Moscow")!
    // 2026-10-15 13:42:07 UTC == 16:42:07 MSK
    let date = Date(timeIntervalSince1970: 1_792_071_727)

    @Test func baseNameUsesLocalTime() {
        #expect(CallRecordingLayout.baseName(startedAt: date, timeZone: moscow)
                == "rec 2026-10-15 16-42-07")
    }
    @Test func folderNameAddsSuffixFromSecondAttempt() {
        #expect(CallRecordingLayout.folderName(base: "rec X", attempt: 1) == "rec X")
        #expect(CallRecordingLayout.folderName(base: "rec X", attempt: 2) == "rec X (2)")
    }
    @Test func trackFilesFollowTheFolder() {
        #expect(CallRecordingLayout.trackFileName(folderName: "rec X (2)", track: .me) == "rec X (2) Me.m4a")
        #expect(CallRecordingLayout.trackFileName(folderName: "rec X", track: .others) == "rec X Others.m4a")
    }
    @Test func transcriptTitle() {
        #expect(CallRecordingLayout.transcriptTitle(startedAt: date, timeZone: moscow)
                == "Call 2026-10-15 16:42")
    }
    @Test func defaultDirectory() {
        #expect(CallRecordingLayout.defaultDirectory.path.hasSuffix(
            "Library/Application Support/Macomprendo/Recordings"))
    }
}

struct CallRecordingManifestTests {
    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func newManifestNamesBothTracks() {
        let m = CallRecordingManifest(startedAt: Date(timeIntervalSince1970: 0), folderName: "rec X")
        #expect(m.version == 1)
        #expect(m.status == .recording)
        #expect(m.track(.me) == .init(file: "rec X Me.m4a", startOffset: nil))
        #expect(m.track(.others) == .init(file: "rec X Others.m4a", startOffset: nil))
    }
    @Test func roundTrip() throws {
        let folder = try tempFolder()
        var m = CallRecordingManifest(startedAt: Date(timeIntervalSince1970: 1_792_071_727), folderName: "rec X")
        m.setStartOffset(0.184, for: .others)
        m.status = .finished
        try m.write(to: folder)
        #expect(try CallRecordingManifest.read(from: folder) == m)
        // no temp file is left beside it
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["recording.json"])
    }
    @Test func unknownVersionIsRejected() throws {
        let folder = try tempFolder()
        let json = #"{"version":2,"startedAt":"2026-10-15T13:42:07Z","status":"finished","tracks":{}}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("recording.json"))
        #expect(throws: MacomprendoError.callRecordingUnavailable) {
            try CallRecordingManifest.read(from: folder)
        }
    }
    @Test func missingManifestIsUnavailable() throws {
        #expect(throws: MacomprendoError.callRecordingUnavailable) {
            try CallRecordingManifest.read(from: try tempFolder())
        }
    }
}
