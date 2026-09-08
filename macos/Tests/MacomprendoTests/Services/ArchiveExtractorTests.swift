import Foundation
import Testing
@testable import Macomprendo

@Suite struct ArchiveExtractorTests {
    private let fileManager = FileManager.default

    @Test func extractsTheSingleArchiveRootDirectlyIntoTheDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try fixture.archive(roots: [
            "voice": [
                "model.onnx": Data("model".utf8),
                "tokens.txt": Data("tokens".utf8),
                "espeak-ng-data/data": Data("phonemes".utf8)
            ]
        ])
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)

        try await TarArchiveExtractor().extract(archive: archive, to: destination, modelID: "voice")

        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("model.onnx").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("tokens.txt").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("espeak-ng-data/data").path))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("voice").path))
    }

    @Test func rejectsAnArchiveWithMoreThanOneTopLevelRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try fixture.archive(roots: [
            "first": ["model.onnx": Data()],
            "second": ["tokens.txt": Data()]
        ])
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)

        await #expect(throws: MacomprendoError.modelDownloadFailed("voice")) {
            try await TarArchiveExtractor().extract(archive: archive, to: destination, modelID: "voice")
        }
        #expect(!fileManager.fileExists(atPath: destination.path))
    }

    @Test func rejectsAnArchiveContainingASymbolicLink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try fixture.archiveWithSymbolicLink()
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)

        await #expect(throws: MacomprendoError.modelDownloadFailed("voice")) {
            try await TarArchiveExtractor().extract(archive: archive, to: destination, modelID: "voice")
        }
        #expect(!fileManager.fileExists(atPath: destination.path))
    }

    @Test func successfulExtractionReplacesAnExistingDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try fixture.archive(roots: ["voice": ["model.onnx": Data("new".utf8)]])
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldFile = destination.appendingPathComponent("old-model.onnx")
        try Data("old".utf8).write(to: oldFile)

        try await TarArchiveExtractor().extract(archive: archive, to: destination, modelID: "voice")

        #expect(!fileManager.fileExists(atPath: oldFile.path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("model.onnx")) ==
                Data("new".utf8))
    }

    @Test func failedExtractionLeavesAnExistingDestinationUntouched() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let malformed = fixture.root.appendingPathComponent("broken.tar.bz2")
        try Data("not an archive".utf8).write(to: malformed)
        let destination = fixture.root.appendingPathComponent("installed", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep-me")
        try Data("old".utf8).write(to: marker)

        await #expect(throws: MacomprendoError.modelDownloadFailed("voice")) {
            try await TarArchiveExtractor().extract(archive: malformed, to: destination, modelID: "voice")
        }
        #expect(try Data(contentsOf: marker) == Data("old".utf8))
    }
}

private struct Fixture {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("Macomprendo-ArchiveExtractorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func archive(roots: [String: [String: Data]]) throws -> URL {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        for (rootName, files) in roots {
            for (relativePath, data) in files {
                let url = source.appendingPathComponent(rootName, isDirectory: true)
                    .appendingPathComponent(relativePath)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }

        let archive = root.appendingPathComponent("fixture-\(UUID().uuidString).tar.bz2")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cjf", archive.path, "-C", source.path] + roots.keys.sorted()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacomprendoError.modelDownloadFailed("fixture")
        }
        return archive
    }

    func archiveWithSymbolicLink() throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let modelRoot = source.appendingPathComponent("voice", isDirectory: true)
        try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: modelRoot.appendingPathComponent("model.onnx"))
        try fileManager.createSymbolicLink(
            at: modelRoot.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "../../outside"))

        let archive = root.appendingPathComponent("fixture.tar.bz2")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cjf", archive.path, "-C", source.path, "voice"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacomprendoError.modelDownloadFailed("fixture")
        }
        return archive
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }
}
