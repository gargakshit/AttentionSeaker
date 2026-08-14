import Foundation
import Security

protocol TokenStoring {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account = "github.com"

    init(service: String = Bundle.main.bundleIdentifier ?? "me.potatokitty.AttentionSeaker") {
        self.service = service
    }

    func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidData
        }
        return token
    }

    func saveToken(_ token: String) throws {
        try deleteToken()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .status(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        case .invalidData:
            return "The GitHub credential in Keychain is invalid."
        }
    }
}

