import Foundation
import Security

enum ZCodeQuotaRegion: String, CaseIterable, Identifiable {
    case bigModel = "bigmodel"
    case zAI = "zai"

    static let defaultsKey = "zCodeQuotaRegion"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bigModel: "BigModel（国内）"
        case .zAI: "Z.ai（海外）"
        }
    }

    var apiKeyName: String {
        switch self {
        case .bigModel: "BigModel API Key"
        case .zAI: "Z.ai API Key"
        }
    }

    var environmentKey: String {
        switch self {
        case .bigModel: "BIGMODEL_API_KEY"
        case .zAI: "Z_AI_API_KEY"
        }
    }

    fileprivate var keychainAccount: String {
        switch self {
        case .bigModel: "zcode-bigmodel-api-key"
        case .zAI: "zcode-zai-api-key"
        }
    }
}

protocol ZCodeAPIKeyStoring {
    func load(for region: ZCodeQuotaRegion) throws -> String?
    func store(_ value: String?, for region: ZCodeQuotaRegion) throws
}

enum ZCodeAPIKeyStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "无法访问钥匙串（\(status)）"
        case .invalidData: return "钥匙串中的 ZCode API Key 格式无效"
        }
    }
}

/// Stores only the key the user explicitly enters in Vibe Usage. It never
/// reads ZCode's own auth database or another application's Keychain items.
struct KeychainZCodeAPIKeyStore: ZCodeAPIKeyStoring {
    private let service: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        // A locally re-signed test app must not query the release app's saved
        // item: macOS would correctly ask the user to approve the unfamiliar
        // signature. UI tests can opt into an empty, isolated namespace; the
        // hook and environment key are absent from Release binaries.
        let testService = environment["VIBE_USAGE_TEST_KEYCHAIN_SERVICE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let testService, !testService.isEmpty {
            self.service = testService
        } else {
            self.service = "ai.vibecafe.vibe-usage"
        }
        #else
        self.service = "ai.vibecafe.vibe-usage"
        #endif
    }

    func load(for region: ZCodeQuotaRegion) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: region.keychainAccount,
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

    func store(_ value: String?, for region: ZCodeQuotaRegion) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: region.keychainAccount,
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
