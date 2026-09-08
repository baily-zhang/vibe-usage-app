import Foundation
import Security

protocol ZCodeAPIKeyStoring {
    func load() throws -> String?
    func store(_ value: String?) throws
}

enum ZCodeAPIKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "无法访问钥匙串（\(status)）"
        case .invalidData: return "钥匙串中的 Z.ai API Key 格式无效"
        }
    }
}

/// Stores only the key the user explicitly enters in Vibe Usage. It never
/// reads ZCode's own auth database or another application's Keychain items.
struct KeychainZCodeAPIKeyStore: ZCodeAPIKeyStoring {
    private let service = "ai.vibecafe.vibe-usage"
    private let account = "zcode-zai-api-key"

    func load() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ZCodeAPIKeyStoreError.keychain(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw ZCodeAPIKeyStoreError.invalidData }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func store(_ value: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ZCodeAPIKeyStoreError.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ZCodeAPIKeyStoreError.keychain(updateStatus)
        }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ZCodeAPIKeyStoreError.keychain(addStatus) }
    }
}
