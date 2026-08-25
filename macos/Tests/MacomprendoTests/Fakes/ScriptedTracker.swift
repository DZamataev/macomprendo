import Foundation
@testable import Macomprendo

struct ScriptedTracker: FrontmostAppTracking {
    var app: FrontmostApp? = FrontmostApp(pid: 42, bundleID: "com.example.editor", name: "Editor")

    func capture() -> FrontmostApp? { app }
    func activate(_ app: FrontmostApp) async -> Bool { true }
}
