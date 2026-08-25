import Foundation
@testable import Macomprendo

final class ScriptedInserter: TextInserting, @unchecked Sendable {
    struct Call: Equatable {
        var text: String
        var app: FrontmostApp?
        var method: InsertMethod
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    var failure: MacomprendoError?

    var calls: [Call] { lock.withLock { recorded } }

    func insert(_ text: String, into app: FrontmostApp?, method: InsertMethod) async throws {
        if let failure { throw failure }
        lock.withLock { recorded.append(Call(text: text, app: app, method: method)) }
    }
}
