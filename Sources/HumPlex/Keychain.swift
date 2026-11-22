import Foundation
import Security

/// The Plex auth token in the login keychain as a generic password.
///
/// Deliberately not a file in `~/.config/hum`: the token is equivalent to the
/// account password for library access, and an unbundled CLI still gets proper
/// ACL protection from the keychain.
public enum Keychain {
    public static let service = "com.hum.plex"

    public enum Failure: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    public static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw Failure.unexpectedStatus(updateStatus) }
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    /// Why a lookup did not return a token.
    ///
    /// "Absent" and "refused" need different words on screen. The keychain
    /// entry's ACL is tied to the signing identity of the binary that created
    /// it, and an ad-hoc signature's identity is the hash of that exact
    /// binary — so a rebuilt or separately-installed hum is a different
    /// caller and can be refused a token that is sitting right there.
    /// Reporting that as "no stored token" sends you through the sign-in flow
    /// to replace something you already have.
    public enum Lookup: Equatable {
        case found(String)
        case absent
        /// The item exists but this binary may not read it.
        case refused(OSStatus)
        case failed(OSStatus)

        public var token: String? {
            if case .found(let token) = self { return token }
            return nil
        }
    }

    /// Classifies a `SecItemCopyMatching` status. Pure, so it is testable
    /// without touching a keychain.
    public static func classify(_ status: OSStatus) -> Lookup {
        switch status {
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled,
             errSecMissingEntitlement:
            return .refused(status)
        default:
            return .failed(status)
        }
    }

    public static func lookup(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return classify(status) }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return .failed(status) }
        return .found(token)
    }

    public static func get(account: String) -> String? {
        lookup(account: account).token
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// Non-secret, machine-local settings: the client identifier Plex uses to
/// recognise this install, and the last server/library we were pointed at.
public struct Preferences: Codable, Sendable {
    public var clientIdentifier: String
    public var lastServerIdentifier: String?
    public var lastSectionID: String?
    public var volume: Float

    public init(
        clientIdentifier: String = UUID().uuidString,
        lastServerIdentifier: String? = nil,
        lastSectionID: String? = nil,
        volume: Float = 0.7
    ) {
        self.clientIdentifier = clientIdentifier
        self.lastServerIdentifier = lastServerIdentifier
        self.lastSectionID = lastSectionID
        self.volume = volume
    }

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("hum/preferences.json")
    }

    /// Decodes preferences, repairing a blank client identifier.
    ///
    /// The `UUID()` default belongs to the memberwise initialiser, not to
    /// `Codable`, so `{"clientIdentifier": ""}` decodes perfectly happily. It
    /// then reaches the sign-in URL as `clientID=`, and Plex answers that with
    /// "We were unable to complete this request" — after the sign-in, which
    /// makes it look like the account's problem rather than ours.
    ///
    /// Separate from `load` so it can be tested without a file.
    public static func decode(_ data: Data) -> Preferences? {
        guard var decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return nil
        }
        if decoded.clientIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decoded.clientIdentifier = UUID().uuidString
        }
        return decoded
    }

    /// Reads preferences, minting a fresh client identifier on first run. A
    /// corrupt file is replaced rather than fatal — it holds nothing precious.
    public static func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = Self.decode(data)
        else {
            let fresh = Preferences()
            try? fresh.save()
            return fresh
        }
        // Persist a repaired identifier, or every run mints another one and
        // the account collects a device per launch.
        try? decoded.save()
        return decoded
    }

    public func save() throws {
        let url = Preferences.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
