import Foundation
import SQLite3
import CommonCrypto
import Security

public final class ChromiumCookieReader: CookieReader {
    public let browser: SupportedBrowser

    private let cookieDBPath: String
    private let keychainService: String

    public init?(browser: SupportedBrowser) {
        self.browser = browser
        let home = NSHomeDirectory()
        switch browser {
        case .brave:
            self.cookieDBPath = "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"
            self.keychainService = "Brave Safe Storage"
        case .chrome:
            self.cookieDBPath = "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"
            self.keychainService = "Chrome Safe Storage"
        case .edge:
            self.cookieDBPath = "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies"
            self.keychainService = "Microsoft Edge Safe Storage"
        case .safari:
            return nil
        }
    }

    public func isAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: cookieDBPath)
    }

    public func readYouTubeCookies() throws -> [ImportedCookie] {
        guard isAvailable() else { throw CookieReadError.browserNotInstalled }
        let key = try fetchKeychainKey()
        let derivedKey = try deriveAESKey(from: key)
        return try queryCookies(decryptingWith: derivedKey)
    }

    private func fetchKeychainKey() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw CookieReadError.keychainAccessDenied
            }
            throw CookieReadError.keychainKeyMissing
        }
        return data
    }

    private func deriveAESKey(from passphrase: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var derived = Data(count: 16)
        let result = derived.withUnsafeMutableBytes { (derivedPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            return passphrase.withUnsafeBytes { (passPtr: UnsafeRawBufferPointer) -> Int32 in
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr.bindMemory(to: Int8.self).baseAddress, passphrase.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    derivedPtr.bindMemory(to: UInt8.self).baseAddress, 16
                )
            }
        }
        guard result == 0 else { throw CookieReadError.parseFailed("pbkdf2") }
        return derived
    }

    private func decryptValue(_ blob: Data, key: Data) throws -> String {
        guard blob.count > 3 else { return "" }
        let prefix = blob.prefix(3)
        let body: Data
        if prefix == Data("v10".utf8) || prefix == Data("v11".utf8) {
            body = blob.dropFirst(3)
        } else {
            return String(data: blob, encoding: .utf8) ?? ""
        }
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            return body.withUnsafeBytes { bodyPtr -> CCCryptorStatus in
                return iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                    return key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            bodyPtr.baseAddress, body.count,
                            outPtr.baseAddress, outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CookieReadError.parseFailed("aes-decrypt") }
        out.count = moved
        if let s = String(data: out, encoding: .utf8) { return s }
        if out.count >= 32 {
            let stripped = out.dropFirst(32)
            return String(data: stripped, encoding: .utf8) ?? ""
        }
        return ""
    }

    private func queryCookies(decryptingWith key: Data) throws -> [ImportedCookie] {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tunesync-cookies-\(UUID().uuidString).db")
        try FileManager.default.copyItem(atPath: cookieDBPath, toPath: tmpURL.path)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CookieReadError.databaseUnreadable("open")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT name, value, encrypted_value, host_key, path, expires_utc, is_secure, is_httponly
        FROM cookies
        WHERE host_key LIKE '%.youtube.com' OR host_key LIKE '%youtube.com'
           OR host_key LIKE '%.google.com'  OR host_key LIKE '%google.com'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CookieReadError.databaseUnreadable("prepare")
        }
        defer { sqlite3_finalize(stmt) }

        var out: [ImportedCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let plainValue = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let encBytes = sqlite3_column_bytes(stmt, 2)
            let encBlob = sqlite3_column_blob(stmt, 2)
            let host = String(cString: sqlite3_column_text(stmt, 3))
            let path = String(cString: sqlite3_column_text(stmt, 4))
            let expiresMicros = sqlite3_column_int64(stmt, 5)
            let isSecure = sqlite3_column_int(stmt, 6) != 0
            let isHTTPOnly = sqlite3_column_int(stmt, 7) != 0

            guard CookieScope.matches(host: host) else { continue }

            let value: String
            if encBytes > 0, let blobPtr = encBlob {
                let blob = Data(bytes: blobPtr, count: Int(encBytes))
                value = (try? decryptValue(blob, key: key)) ?? plainValue
            } else {
                value = plainValue
            }

            let expires: Date?
            if expiresMicros > 0 {
                let chromiumEpoch = Date(timeIntervalSince1970: -11644473600)
                expires = chromiumEpoch.addingTimeInterval(TimeInterval(expiresMicros) / 1_000_000)
            } else {
                expires = nil
            }

            out.append(ImportedCookie(
                name: name, value: value, domain: host, path: path,
                expires: expires, isSecure: isSecure, isHTTPOnly: isHTTPOnly
            ))
        }
        return out
    }
}
