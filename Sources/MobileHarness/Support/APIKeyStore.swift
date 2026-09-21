import Foundation
import Security

/// Stores service API keys such as the OpenRouter and ElevenLabs keys.
///
/// Use ``KeychainAPIKeyStore`` in applications so keys never live in
/// `UserDefaults`, property lists, or source code. Use
/// ``InMemoryAPIKeyStore`` in tests and previews.
public protocol APIKeyStore: Sendable {
    /// Persists the key for the given service, replacing any previous value.
    func saveAPIKey(_ key: String, for service: String) async throws

    /// Loads the key for the given service, or `nil` when none is stored.
    func loadAPIKey(for service: String) async throws -> String?

    /// Removes the key for the given service. Removing an absent key succeeds.
    func deleteAPIKey(for service: String) async throws
}

/// Well-known service names used by the harness.
public enum APIKeyService {
    /// The service name for OpenRouter API keys.
    public static let openRouter = "MobileHarness.OpenRouter"
    /// The service name for ElevenLabs API keys.
    public static let elevenLabs = "MobileHarness.ElevenLabs"
}

/// An ``APIKeyStore`` that keeps keys in the device keychain.
///
/// Keys are stored as generic-password items with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they remain available
/// for background agent runs while never leaving the device — not even in
/// backups. Writes use the add-or-update pattern and every `OSStatus` is
/// checked; device-locked failures (`errSecInteractionNotAllowed`) surface as
/// ``HarnessError/keychainStatus(_:)`` rather than deleting the item.
///
/// ```swift
/// let store = KeychainAPIKeyStore()
/// try await store.saveAPIKey(openRouterKey, for: APIKeyService.openRouter)
/// let agent = Agent(openRouterAPIKey: try await store.loadAPIKey(for: APIKeyService.openRouter)!)
/// ```
public struct KeychainAPIKeyStore: APIKeyStore {
    /// The keychain service under which items are stored.
    private let service: String
    /// Whether macOS targets the data protection keychain (recommended) or the
    /// legacy file-based keychain. `nil` follows the platform default.
    private let usesDataProtectionKeychain: Bool?

    /// Creates a store that persists keys under the given keychain service.
    ///
    /// - Parameters:
    ///   - service: The keychain service identifier; namespaced per app.
    ///   - useDataProtectionKeychain: Overrides the macOS keychain routing. The
    ///     default targets the data protection keychain, which requires the
    ///     host process to be signed with keychain entitlements — pass `false`
    ///     only for unsigned tools and test processes using the legacy
    ///     file-based keychain.
    public init(service: String = "MobileHarness.APIKeys", useDataProtectionKeychain: Bool? = nil) {
        self.service = service
        self.usesDataProtectionKeychain = useDataProtectionKeychain
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let useDataProtection = usesDataProtectionKeychain ?? true
        #if os(macOS)
        if useDataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }
        #endif
        return query
    }

    public func saveAPIKey(_ key: String, for account: String) async throws {
        let data = Data(key.utf8)
        let baseQuery = baseQuery(account: account)

        var addQuery = baseQuery
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updates: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw HarnessError.keychainStatus(updateStatus)
            }
        default:
            throw HarnessError.keychainStatus(addStatus)
        }
    }

    public func loadAPIKey(for account: String) async throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw HarnessError.keychainStatus(errSecParam)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw HarnessError.keychainStatus(status)
        }
    }

    public func deleteAPIKey(for account: String) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HarnessError.keychainStatus(status)
        }
    }
}

/// An ``APIKeyStore`` that keeps keys in memory.
///
/// Intended for unit tests, SwiftUI previews, and playgrounds — anything stored
/// here is discarded when the process exits.
public actor InMemoryAPIKeyStore: APIKeyStore {
    private var keys: [String: String] = [:]

    /// Creates an empty store.
    public init() {}

    public func saveAPIKey(_ key: String, for service: String) async throws {
        keys[service] = key
    }

    public func loadAPIKey(for service: String) async throws -> String? {
        keys[service]
    }

    public func deleteAPIKey(for service: String) async throws {
        keys.removeValue(forKey: service)
    }
}
