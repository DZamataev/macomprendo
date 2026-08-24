import Testing
@testable import Macomprendo

@Test func loggerSubsystemMatchesTheBundleIdentifier() {
    #expect(Log.subsystem == "com.dzamataev.macomprendo")
}
