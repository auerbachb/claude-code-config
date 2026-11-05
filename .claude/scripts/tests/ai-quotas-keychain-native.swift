// Synthetic private-Keychain integration test. Never opens a production item.
import Foundation
import Security

struct ProbeFailure: Error { let step: String; let status: OSStatus }
func require(_ status: OSStatus, _ step: String) throws {
    if status != errSecSuccess { throw ProbeFailure(step: step, status: status) }
}
func searchPaths() throws -> [String] {
    var list: CFArray?
    try require(SecKeychainCopySearchList(&list), "search-list")
    return try (list as? [SecKeychain] ?? []).map { kc in
        var length: UInt32 = 4096
        var bytes = [CChar](repeating: 0, count: Int(length))
        try require(SecKeychainGetPath(kc, &length, &bytes), "keychain-path")
        return String(cString: bytes)
    }
}
func aclFingerprint(_ item: SecKeychainItem) throws -> [String] {
    var access: SecAccess?
    try require(SecKeychainItemCopyAccess(item, &access), "access")
    var list: CFArray?
    try require(SecAccessCopyACLList(access!, &list), "acl-list")
    return try (list as? [SecACL] ?? []).map { acl in
        var apps: CFArray?, desc: CFString?
        var prompt = SecKeychainPromptSelector(rawValue: 0)
        try require(SecACLCopyContents(acl, &apps, &desc, &prompt), "acl-contents")
        let appData = try (apps as? [SecTrustedApplication] ?? []).map { app -> String in
            var data: CFData?
            try require(SecTrustedApplicationCopyData(app, &data), "trusted-app")
            return (data! as Data).base64EncodedString()
        }
        let auth = (SecACLCopyAuthorizations(acl) as NSArray).map { String(describing: $0) }
        return String(describing: desc) + "|" + String(prompt.rawValue) + "|" + appData.sorted().joined(separator: ",") + "|" + auth.sorted().joined(separator: ",")
    }.sorted()
}
func run() throws {
    try require(SecKeychainSetUserInteractionAllowed(false), "disable-ui")
    let before = try searchPaths()
    var kc: SecKeychain?
    let path = CommandLine.arguments[1]
    guard URL(fileURLWithPath: path).lastPathComponent == "fixture-private.keychain-db",
          !path.contains("/login.keychain"),
          !FileManager.default.fileExists(atPath: path) else {
        throw ProbeFailure(step: "private-fixture-path", status: -1)
    }
    try "".withCString { empty in try require(SecKeychainCreate(path, 0, empty, false, nil, &kc), "create-private") }
    defer { if let kc { _ = SecKeychainDelete(kc) } }
    guard let keychain = kc else { throw ProbeFailure(step: "created-reference", status: -1) }
    guard try searchPaths() == before else { throw ProbeFailure(step: "private-create-changed-search-list", status: -1) }
    let account = "fixture-account"
    let services = ["fixture-source-alpha", "fixture-source-beta"]
    let bytes = [Data("fixed-fixture-alpha".utf8), Data("fixed-fixture-beta".utf8)]
    var items: [SecKeychainItem] = []
    for i in 0..<2 {
        var item: SecKeychainItem?
        let result = services[i].withCString { service in account.withCString { acct in
            bytes[i].withUnsafeBytes { data in SecKeychainAddGenericPassword(keychain, UInt32(services[i].utf8.count), service, UInt32(account.utf8.count), acct, UInt32(bytes[i].count), data.baseAddress!, &item) }
        }}
        try require(result, "add-synthetic")
        items.append(item!)
    }
    let aclBefore = try items.map(aclFingerprint)
    func query(_ service: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecMatchSearchList as String: [keychain]]
    }
    let adapter = try KeychainMetadata(keychain: keychain)
    for service in services {
        guard try adapter.accounts(service) == [account] else { throw ProbeFailure(step: "metadata-only-inspect", status: -1) }
    }
    do {
        try adapter.rename(services[0], services[1], account: account)
        throw ProbeFailure(step: "collision-not-refused", status: -1)
    } catch is MetadataFailure { }
    func rename(_ source: String, _ target: String) throws {
        try adapter.rename(source, target, account: account)
    }
    try rename(services[0], "fixture-stage-alpha")
    try rename(services[1], "fixture-stage-beta")
    try rename("fixture-stage-alpha", services[1])
    try rename("fixture-stage-beta", services[0])
    for i in 0..<2 {
        var q = query(services[1-i]); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try require(SecItemCopyMatching(q as CFDictionary, &result), "read-synthetic-only")
        guard result as? Data == bytes[i] else { throw ProbeFailure(step: "synthetic-data-changed", status: -1) }
    }
    guard try items.map(aclFingerprint) == aclBefore else { throw ProbeFailure(step: "acl-changed", status: -1) }
    guard try searchPaths() == before else { throw ProbeFailure(step: "search-list-changed", status: -1) }
    try require(SecKeychainDelete(keychain), "delete-private")
    kc = nil
    guard try searchPaths() == before else { throw ProbeFailure(step: "delete-changed-search-list", status: -1) }
    print("native_keychain_test: production adapter preserved synthetic bytes and ACLs; collision refused; search list unchanged")
}
@main
struct KeychainMetadataIntegrationTest {
    static func main() {
        do { try run() }
        catch let e as ProbeFailure { fputs("native test failed at \(e.step), status \(e.status)\n", stderr); exit(1) }
        catch let e as MetadataFailure { fputs("native adapter failed at \(e.operation), status \(e.status)\n", stderr); exit(1) }
        catch { fputs("native test failed\n", stderr); exit(1) }
    }
}
