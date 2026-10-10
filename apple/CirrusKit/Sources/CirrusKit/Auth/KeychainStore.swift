#if canImport(Security)
    import Foundation
    import Security

    /// Generic-password Keychain items of one service: the profile list under
    /// `cirrus.profiles.v1` and OAuth tokens under `cirrus.oauth.<profile id>`.
    public final class KeychainStore: OAuthTokenStore, @unchecked Sendable {
        public static let service = "io.felixbennett.cirrus"
        public static let profilesKey = "cirrus.profiles.v1"

        let service: String
        private let lock = NSLock()

        public init(service: String = KeychainStore.service) {
            self.service = service
        }

        // MARK: Items

        private func baseQuery(_ account: String, dataProtection: Bool) -> [CFString: Any] {
            var q: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ]
            #if os(macOS)
                q[kSecUseDataProtectionKeychain] = dataProtection
            #endif
            return q
        }

        /// The item's text, or nil. On macOS the data-protection keychain is
        /// tried first, then the login keychain.
        public func read(_ account: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            for dp in Self.keychains {
                var q = baseQuery(account, dataProtection: dp)
                q[kSecReturnData] = true
                q[kSecMatchLimit] = kSecMatchLimitOne
                var out: CFTypeRef?
                if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                    return String(data: data, encoding: .utf8)
                }
            }
            return nil
        }

        /// Stores [value], replacing the existing item.
        public func write(_ account: String, _ value: String) throws {
            lock.lock()
            defer { lock.unlock() }
            let data = Data(value.utf8)
            var lastStatus: OSStatus = errSecSuccess
            for dp in Self.keychains {
                let q = baseQuery(account, dataProtection: dp)
                let update: [CFString: Any] = [
                    kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                ]
                var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
                if status == errSecItemNotFound {
                    var add = q
                    add[kSecValueData] = data
                    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
                    status = SecItemAdd(add as CFDictionary, nil)
                }
                if status == errSecSuccess { return }
                lastStatus = status
                // Unsigned macOS builds can't use the data-protection keychain
                // (errSecMissingEntitlement): fall back to the login keychain.
                if status != errSecMissingEntitlement { break }
            }
            throw KeychainError(status: lastStatus)
        }

        public func delete(_ account: String) {
            lock.lock()
            defer { lock.unlock() }
            for dp in Self.keychains {
                SecItemDelete(baseQuery(account, dataProtection: dp) as CFDictionary)
            }
        }

        #if os(macOS)
            static let keychains = [true, false]
        #else
            static let keychains = [true]
        #endif

        // MARK: Profiles

        public func loadProfiles() -> [Profile] {
            FlutterAppData.parseProfiles(read(Self.profilesKey))
        }

        public func saveProfiles(_ profiles: [Profile]) throws {
            let data = try JSONEncoder.compact.encode(profiles)
            try write(Self.profilesKey, String(decoding: data, as: UTF8.self))
        }

        // MARK: OAuth tokens

        static func tokensKey(_ id: String) -> String { "cirrus.oauth.\(id)" }

        public func readTokens(profileId: String) async -> OAuthTokens? {
            FlutterAppData.parseTokens(read(Self.tokensKey(profileId)))
        }

        public func writeTokens(profileId: String, _ tokens: OAuthTokens) async throws {
            let data = try JSONEncoder.compact.encode(tokens)
            try write(Self.tokensKey(profileId), String(decoding: data, as: UTF8.self))
        }

        public func deleteTokens(profileId: String) async {
            delete(Self.tokensKey(profileId))
        }
    }

    public struct KeychainError: Error, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    /// Reads (never writes) the Flutter app's Keychain items.
    public enum FlutterKeychain {
        public static func read(_ account: String) -> String? {
            KeychainStore(service: FlutterAppData.keychainService).read(account)
        }
    }
#endif
