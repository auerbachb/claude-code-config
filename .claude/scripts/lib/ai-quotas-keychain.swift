import Foundation
import Security

// This adapter never requests item data. Only the service attribute is mutable.
struct MetadataFailure: Error {
    let operation: String
    let status: OSStatus
}

struct KeychainMetadata {
    let keychain: SecKeychain?

    init(keychain: SecKeychain? = nil) throws {
        self.keychain = keychain
        // Process-local policy for legacy file-based Keychains; never prompt.
        try check(SecKeychainSetUserInteractionAllowed(false), "disable-ui")
    }

    func check(_ status: OSStatus, _ operation: String) throws {
        if status != errSecSuccess {
            throw MetadataFailure(operation: operation, status: status)
        }
    }

    func query(_ service: String) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let keychain {
            result[kSecMatchSearchList as String] = [keychain]
        }
        return result
    }

    func accounts(_ service: String) throws -> [String] {
        var request = query(service)
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = false
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "inspect")
        guard let rows = result as? [[String: Any]] else {
            throw MetadataFailure(operation: "metadata-shape", status: errSecParam)
        }
        let accounts = rows.compactMap { $0[kSecAttrAccount as String] as? String }
        guard accounts.count == rows.count else {
            throw MetadataFailure(operation: "metadata-shape", status: errSecParam)
        }
        return accounts.sorted()
    }

    func rename(_ source: String, _ target: String, account: String) throws {
        guard source != target,
              try accounts(source) == [account],
              try accounts(target).isEmpty else {
            throw MetadataFailure(operation: "ambiguous-or-occupied", status: errSecDuplicateItem)
        }
        var request = query(source)
        request[kSecAttrAccount as String] = account
        // No return keys, value-data updates, ACL updates, or delete/add calls.
        try check(SecItemUpdate(request as CFDictionary,
                               [kSecAttrService as String: target] as CFDictionary), "rename")
        // Nothing fallible after the atomic update: the caller records its phase.
    }
}

#if !KEYCHAIN_TESTING
@main
struct KeychainMetadataCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let store = try KeychainMetadata()
            if args.count == 2 && args[0] == "inspect" {
                let accounts = try store.accounts(args[1])
                let data = try JSONSerialization.data(withJSONObject: ["accounts": accounts], options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            } else if args.count == 4 && args[0] == "rename" {
                try store.rename(args[1], args[2], account: args[3])
            } else {
                throw MetadataFailure(operation: "arguments", status: errSecParam)
            }
        } catch let error as MetadataFailure {
            fputs("Keychain metadata \(error.operation) failed (OSStatus \(error.status))\n", stderr)
            exit(5)
        } catch {
            fputs("Keychain metadata operation failed\n", stderr)
            exit(5)
        }
    }
}
#endif
