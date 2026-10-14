import Foundation
@testable import Macomprendo

struct FakeFileBookmarks: FileBookmarking {
    let missing: Set<String>

    init(missing: Set<String> = []) {
        self.missing = missing
    }

    func bookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard let path = String(data: bookmark, encoding: .utf8) else {
            throw MacomprendoError.sourceFileUnavailable
        }
        guard !missing.contains(path) else {
            throw MacomprendoError.sourceFileUnavailable
        }
        return URL(fileURLWithPath: path)
    }
}
