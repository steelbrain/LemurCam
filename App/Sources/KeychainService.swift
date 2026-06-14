import Foundation
import Security

internal enum KeychainError: Error {
    case encodingFailed
    case decodingFailed
    case unexpectedStatus(OSStatus)
}

internal final class KeychainService {
    private let service = "cam.lemur.app.credentials"

    func save(credentials: SourceCredentials, for sourceID: UUID) throws {
        let data = try encode(credentials)
        let account = sourceID.uuidString

        // Try to update first; if not found, add new
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func retrieve(for sourceID: UUID) throws -> SourceCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return try decode(data)
    }

    func delete(for sourceID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func encode(_ credentials: SourceCredentials) throws -> Data {
        let dict: [String: String] = [
            "username": credentials.username,
            "password": credentials.password
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            throw KeychainError.encodingFailed
        }
        return data
    }

    private func decode(_ data: Data) throws -> SourceCredentials {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let username = dict["username"],
              let password = dict["password"] else {
            throw KeychainError.decodingFailed
        }
        return SourceCredentials(username: username, password: password)
    }
}
