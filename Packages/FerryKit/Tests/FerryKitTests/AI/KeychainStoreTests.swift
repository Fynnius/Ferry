import Foundation
import Testing
@testable import FerryKit

/// Writes a throwaway item (unique service name) to the real Keychain and removes it.
/// Set `FERRY_SKIP_KEYCHAIN_TESTS=1` where no unlocked keychain exists (CI, SSH sessions).
@Suite("Keychain store", .enabled(if: ProcessInfo.processInfo.environment["FERRY_SKIP_KEYCHAIN_TESTS"] == nil))
struct KeychainStoreTests {
    private func throwawayStore() -> KeychainStore {
        KeychainStore(service: "io.github.fynnius.Ferry.tests.\(UUID().uuidString)", account: "api-key")
    }

    @Test func saveReadReplaceDelete() throws {
        let store = throwawayStore()
        defer { try? store.delete() }

        #expect(!store.hasKey)
        #expect(try store.read() == nil)

        try store.save("sk-test-first\n")
        #expect(store.hasKey)
        #expect(try store.read() == "sk-test-first")

        try store.save("sk-test-second")
        #expect(try store.read() == "sk-test-second")

        try store.delete()
        #expect(!store.hasKey)
        #expect(try store.read() == nil)
        try store.delete() // deleting nothing is fine
    }

    @Test func emptyKeyIsRejected() {
        let store = throwawayStore()
        defer { try? store.delete() }
        #expect(throws: KeychainError(status: errSecParam)) { try store.save("  \n") }
        #expect(!store.hasKey)
    }

    @Test func storesAreIsolatedByService() throws {
        let a = throwawayStore()
        let b = throwawayStore()
        defer {
            try? a.delete()
            try? b.delete()
        }
        try a.save("key-a")
        #expect(try b.read() == nil)
        #expect(KeychainStore().service == "io.github.fynnius.Ferry.openai")
    }
}
