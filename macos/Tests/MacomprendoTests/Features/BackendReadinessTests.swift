import Foundation
import Testing
@testable import Macomprendo

@Suite struct BackendReadinessTests {

    private let endpointID = UUID()

    @Test func aDownloadedLocalModelIsReady() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .downloaded],
                                    endpointProbe: nil) == .ready)
    }

    @Test func anUndownloadedLocalModelOffersToDownloadIt() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .notDownloaded],
                                    endpointProbe: nil)
                == .notReady(reason: "This model has not been downloaded yet.",
                             fix: .download(modelID: "base")))
    }

    @Test func anUnknownModelIsTreatedAsNotDownloaded() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"), states: [:], endpointProbe: nil)
                == .notReady(reason: "This model has not been downloaded yet.",
                             fix: .download(modelID: "base")))
    }

    @Test func aDownloadInProgressIsNotReadyAndOffersNoFix() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .downloading(fraction: 0.4)],
                                    endpointProbe: nil)
                == .notReady(reason: "Downloading… 40%", fix: nil))
    }

    @Test func aFailedDownloadReportsTheFailureAndOffersARetry() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .failed("checksum mismatch")],
                                    endpointProbe: nil)
                == .notReady(reason: "checksum mismatch", fix: .download(modelID: "base")))
    }

    @Test func anUnprobedEndpointIsNotReady() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:], endpointProbe: nil)
                == .notReady(reason: "This endpoint has not been tested yet.",
                             fix: .testEndpoint(id: endpointID)))
    }

    @Test func aSuccessfullyProbedEndpointIsReady() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:],
                                    endpointProbe: .succeeded(id: endpointID, model: "whisper-1"))
                == .ready)
    }

    @Test func aProbeOfADifferentServerOrModelCountsAsUntested() {
        // A probe proves that one server answered on one model name. Carrying that verdict
        // over to another endpoint — or another model on the same endpoint — would be exactly
        // the false "ready" the probe exists to prevent.
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:],
                                    endpointProbe: .succeeded(id: UUID(), model: "whisper-1"))
                == .notReady(reason: "This endpoint has not been tested yet.",
                             fix: .testEndpoint(id: endpointID)))
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:],
                                    endpointProbe: .succeeded(id: endpointID, model: "gpt-4o-transcribe"))
                == .notReady(reason: "This endpoint has not been tested yet.",
                             fix: .testEndpoint(id: endpointID)))
    }

    @Test func aFailedProbeReportsWhyAndOffersARetest() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:], endpointProbe: .failed("HTTP 404"))
                == .notReady(reason: "HTTP 404", fix: .testEndpoint(id: endpointID)))
    }

    @Test func anEndpointWithABlankModelNameIsNotReadyEvenAfterASuccessfulProbe() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "  "),
                                    states: [:], endpointProbe: .succeeded(id: endpointID, model: "  "))
                == .notReady(reason: "No model name is set.", fix: .selectModel))
    }
}
