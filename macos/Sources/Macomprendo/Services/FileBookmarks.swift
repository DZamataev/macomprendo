import Foundation

protocol FileBookmarking: Sendable {
    func bookmark(for url: URL) throws -> Data
    /// Throws `MacomprendoError.sourceFileUnavailable` when the data no longer resolves to an
    /// existing file.
    func resolve(_ bookmark: Data) throws -> URL
}

struct FoundationFileBookmarks: FileBookmarking {
    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [])
    }

    func resolve(_ bookmark: Data) throws -> URL {
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark,
                              bookmarkDataIsStale: &isStale)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MacomprendoError.sourceFileUnavailable
            }
            return url
        } catch {
            throw MacomprendoError.sourceFileUnavailable
        }
    }
}
