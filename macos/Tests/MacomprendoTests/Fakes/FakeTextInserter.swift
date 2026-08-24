import Foundation
@testable import Macomprendo

final class FakeTextInserter: TextInserting, @unchecked Sendable {
    struct Insertion: Equatable {
        var text: String
        var app: FrontmostApp?
        var method: InsertMethod
    }

    private let lock = NSLock()
    private var _inserted: [Insertion] = []
    private var _error: Error?

    var inserted: [Insertion] { lock.withLock { _inserted } }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws {
        if let error { throw error }
        lock.withLock { _inserted.append(Insertion(text: text, app: app, method: method)) }
    }
}
