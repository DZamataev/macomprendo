import Testing
@testable import Macomprendo

@Test(arguments: [
    MacomprendoError.permissionDenied(.microphone),
    .permissionDenied(.accessibility),
    .modelMissing("base"),
    .modelDownloadFailed("timeout"),
    .providerUnreachable(endpointName: "Ollama (local)"),
    .providerHTTP(status: 401, body: "unauthorized"),
    .providerStreamMalformed,
    .audio("no input device"),
    .noSelection,
    .insertFailed
])
func everyErrorHasDescriptionAndRecovery(error: MacomprendoError) {
    #expect(error.errorDescription?.isEmpty == false)
    #expect(error.recoverySuggestion?.isEmpty == false)
}

@Test func cancelledHasNoRecoverySuggestion() {
    #expect(MacomprendoError.cancelled.errorDescription == "Cancelled.")
    #expect(MacomprendoError.cancelled.recoverySuggestion == nil)
}

@Test func unreachableErrorNamesTheEndpoint() {
    let error = MacomprendoError.providerUnreachable(endpointName: "Ollama (local)")
    #expect(error.errorDescription?.contains("Ollama (local)") == true)
    #expect(error.recoverySuggestion?.contains("Settings") == true)
}

@Test func httpErrorCarriesStatusAndBody() {
    let error = MacomprendoError.providerHTTP(status: 401, body: "unauthorized")
    #expect(error.errorDescription?.contains("401") == true)
    #expect(error.errorDescription?.contains("unauthorized") == true)
}

@Test func insertFailedTellsTheUserWhereTheTextWent() {
    #expect(MacomprendoError.insertFailed.recoverySuggestion?.contains("⌘V") == true)
}

@Test func errorsAreEquatable() {
    #expect(MacomprendoError.modelMissing("base") == .modelMissing("base"))
    #expect(MacomprendoError.modelMissing("base") != .modelMissing("small"))
}
