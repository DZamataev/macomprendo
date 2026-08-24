import Testing
@testable import Macomprendo

@Test func inMemoryKeychainStoresUpdatesAndDeletes() throws {
    let keychain = InMemoryKeychainStore()
    #expect(try keychain.get(account: "work-key") == nil)

    try keychain.set("sk-one", account: "work-key")
    #expect(try keychain.get(account: "work-key") == "sk-one")

    try keychain.set("sk-two", account: "work-key")
    #expect(try keychain.get(account: "work-key") == "sk-two")

    try keychain.delete(account: "work-key")
    #expect(try keychain.get(account: "work-key") == nil)
}

@Test func accountsAreIndependent() throws {
    let keychain = InMemoryKeychainStore()
    try keychain.set("a", account: "one")
    try keychain.set("b", account: "two")
    #expect(try keychain.get(account: "one") == "a")
    #expect(try keychain.get(account: "two") == "b")
}

@Test func deletingAMissingAccountIsNotAnError() throws {
    try InMemoryKeychainStore().delete(account: "nope")
}

@Test func systemKeychainStoreDefaultsToTheAppService() {
    #expect(SystemKeychainStore().service == "com.dzamataev.macomprendo")
}
