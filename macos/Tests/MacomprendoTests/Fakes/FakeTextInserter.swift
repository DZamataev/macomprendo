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
    private var _gate: AsyncGate?

    var inserted: [Insertion] { lock.withLock { _inserted } }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    /// Blocks `insert(_:into:method:)` until the test opens it — for asserting what
    /// happens if the controller is cancelled while an insert is in flight.
    var gate: AsyncGate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws {
        if let gate { await gate.wait() }
        if let error { throw error }
        lock.withLock { _inserted.append(Insertion(text: text, app: app, method: method)) }
    }
}
