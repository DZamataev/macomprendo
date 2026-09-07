import Foundation

/// Extracts one verified model archive into its final model directory.
protocol ArchiveExtracting: Sendable {
    func extract(archive: URL, to destination: URL, modelID: String) async throws
}

/// The TTS assets are bzip2 tar archives with one top-level directory. Extraction happens in
/// a sibling staging directory so a partial or malformed archive is never visible as a model.
struct TarArchiveExtractor: ArchiveExtracting {
    func extract(archive: URL, to destination: URL, modelID: String) async throws {
        do {
            try await Task.detached(priority: .utility) {
                try extractVerifiedLayout(archive: archive, to: destination)
            }.value
        } catch {
            throw MacomprendoError.modelDownloadFailed(modelID)
        }
    }

    private func extractVerifiedLayout(archive: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let listing = try runTar(["-tjf", archive.path])
        guard let text = String(data: listing, encoding: .utf8) else {
            throw ExtractionFailure.invalidListing
        }

        let roots = try topLevelRoots(in: text)
        guard roots.count == 1, let rootName = roots.first else {
            throw ExtractionFailure.invalidLayout
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let suffix = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).extracting-\(suffix)",
                                                  isDirectory: true)
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).backup-\(suffix)",
                                                 isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }

        _ = try runTar(["-xjf", archive.path, "-C", staging.path])
        let extractedRoot = staging.appendingPathComponent(rootName, isDirectory: true)
        let values = try extractedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ExtractionFailure.invalidLayout
        }

        let hadDestination = fileManager.fileExists(atPath: destination.path)
        if hadDestination {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: extractedRoot, to: destination)
            if hadDestination {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if hadDestination,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func topLevelRoots(in listing: String) throws -> Set<String> {
        var roots: Set<String> = []
        for rawLine in listing.split(whereSeparator: \.isNewline) {
            var path = String(rawLine)
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, !path.hasPrefix("/") else {
                throw ExtractionFailure.unsafePath
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first,
                  components.allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw ExtractionFailure.unsafePath
            }
            roots.insert(String(first))
        }
        return roots
    }

    private func runTar(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ExtractionFailure.tarFailed
        }
        return data
    }
}

private enum ExtractionFailure: Error {
    case invalidListing
    case invalidLayout
    case unsafePath
    case tarFailed
}
