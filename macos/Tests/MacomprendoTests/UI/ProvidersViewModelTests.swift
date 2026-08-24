import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct ProvidersViewModelTests {
    @MainActor
    private final class Harness {
        let keychain = InMemoryKeychainStore()
        let provider = StubLLMProvider()
        let puller = StubPuller()
        var saved: [Endpoint] = []
        var viewModel: ProvidersViewModel!

        init(endpoints: [Endpoint] = [Endpoint.ollamaLocal()], pullerAvailable: Bool = true) {
            let provider = self.provider
            let puller = self.puller
            viewModel = ProvidersViewModel(
                endpoints: endpoints,
                update: { [weak self] in self?.saved = $0 },
                keychain: keychain,
                llmFor: { endpoint in
                    provider.endpoint = endpoint
                    return provider
                },
                pullerFor: { _ in pullerAvailable ? puller : nil })
        }
    }

    @Test func keychainAccountsAreNamespacedPerEndpoint() {
        let id = UUID(uuidString: "1D3A6B2E-0000-4000-8000-000000000001")!
        #expect(Endpoint.keychainAccount(for: id) == "endpoint.1D3A6B2E-0000-4000-8000-000000000001")
    }

    @Test func addAppendsAnOpenAICompatibleEndpointAndSaves() {
        let harness = Harness()
        harness.viewModel.add()
        #expect(harness.viewModel.endpoints.count == 2)
        #expect(harness.viewModel.endpoints[1].kind == .openAICompatible)
        #expect(harness.saved.count == 2)
    }

    @Test func updateReplacesAnEndpointInPlace() {
        let harness = Harness()
        var endpoint = harness.viewModel.endpoints[0]
        endpoint.name = "Renamed"
        harness.viewModel.update(endpoint)
        #expect(harness.viewModel.endpoints[0].name == "Renamed")
        #expect(harness.saved[0].name == "Renamed")
    }

    @Test func settingAnAPIKeyStoresItInTheKeychainAndRecordsTheReference() throws {
        let harness = Harness()
        let endpoint = harness.viewModel.endpoints[0]

        harness.viewModel.setAPIKey("sk-secret", for: endpoint)

        let account = Endpoint.keychainAccount(for: endpoint.id)
        #expect(try harness.keychain.get(account: account) == "sk-secret")
        #expect(harness.viewModel.endpoints[0].apiKeyRef == account)
        #expect(harness.viewModel.apiKey(for: harness.viewModel.endpoints[0]) == "sk-secret")
    }

    @Test func clearingAnAPIKeyDeletesItFromTheKeychain() throws {
        let harness = Harness()
        let endpoint = harness.viewModel.endpoints[0]
        harness.viewModel.setAPIKey("sk-secret", for: endpoint)

        harness.viewModel.setAPIKey("", for: harness.viewModel.endpoints[0])

        #expect(try harness.keychain.get(account: Endpoint.keychainAccount(for: endpoint.id)) == nil)
        #expect(harness.viewModel.endpoints[0].apiKeyRef == nil)
    }

    @Test func removingAnEndpointAlsoRemovesItsKey() throws {
        let harness = Harness()
        let endpoint = harness.viewModel.endpoints[0]
        harness.viewModel.setAPIKey("sk-secret", for: endpoint)

        harness.viewModel.remove(endpoint.id)

        #expect(harness.viewModel.endpoints.isEmpty)
        #expect(try harness.keychain.get(account: Endpoint.keychainAccount(for: endpoint.id)) == nil)
        #expect(harness.saved.isEmpty)
    }

    @Test func testingAConnectionReportsTheModelCount() async {
        let harness = Harness()
        harness.provider.models = .success(["qwen2.5:1.5b", "llama3.2"])
        let endpoint = harness.viewModel.endpoints[0]

        harness.viewModel.testConnection(endpoint)
        await harness.viewModel.testTask?.value

        #expect(harness.viewModel.testResults[endpoint.id] == "Connected — 2 models")
    }

    @Test func aFailedConnectionReportsTheError() async {
        let harness = Harness()
        let failure = MacomprendoError.providerUnreachable(endpointName: "Ollama (local)")
        harness.provider.models = .failure(failure)
        let endpoint = harness.viewModel.endpoints[0]

        harness.viewModel.testConnection(endpoint)
        await harness.viewModel.testTask?.value

        #expect(harness.viewModel.testResults[endpoint.id] == ErrorText.describe(failure))
    }

    @Test func pullingAModelReportsProgressThenCompletion() async {
        let harness = Harness()
        harness.puller.progress = [
            PullProgress(status: "pulling manifest", completed: nil, total: nil),
            PullProgress(status: "downloading", completed: 50, total: 100)
        ]
        let endpoint = harness.viewModel.endpoints[0]

        harness.viewModel.pull(model: "qwen2.5:1.5b", from: endpoint)
        await harness.viewModel.pullTask?.value

        #expect(harness.puller.pulled == ["qwen2.5:1.5b"])
        #expect(harness.viewModel.pullStatus == "Pulled qwen2.5:1.5b")
        #expect(harness.viewModel.pullProgress == nil)
    }

    @Test func aFailedPullReportsTheError() async {
        let harness = Harness()
        let failure = MacomprendoError.providerHTTP(status: 500, body: "boom")
        harness.puller.error = failure
        let endpoint = harness.viewModel.endpoints[0]

        harness.viewModel.pull(model: "qwen2.5:1.5b", from: endpoint)
        await harness.viewModel.pullTask?.value

        #expect(harness.viewModel.pullStatus == ErrorText.describe(failure))
        #expect(harness.viewModel.pullProgress == nil)
    }

    @Test func pullingIsRefusedForNonOllamaEndpoints() async {
        let harness = Harness(pullerAvailable: false)
        let endpoint = harness.viewModel.endpoints[0]

        harness.viewModel.pull(model: "qwen2.5:1.5b", from: endpoint)
        await harness.viewModel.pullTask?.value

        #expect(harness.viewModel.pullStatus == "Only Ollama endpoints can pull models.")
    }
}
