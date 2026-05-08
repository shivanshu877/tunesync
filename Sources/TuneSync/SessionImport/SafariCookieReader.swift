import Foundation

public final class SafariCookieReader: CookieReader {
    public let browser = SupportedBrowser.safari

    private let path: String

    public init() {
        self.path = "\(NSHomeDirectory())/Library/Cookies/Cookies.binarycookies"
    }

    public func isAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    public func readYouTubeCookies() throws -> [ImportedCookie] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw CookieReadError.fullDiskAccessRequired
        }
        return try parse(data)
    }

    func parse(_ data: Data) throws -> [ImportedCookie] {
        guard data.count > 8 else { throw CookieReadError.parseFailed("too small") }
        guard data.subdata(in: 0..<4) == Data("cook".utf8) else {
            throw CookieReadError.parseFailed("bad magic")
        }
        let pageCount = Int(readUInt32BE(data, at: 4))
        guard data.count >= 8 + pageCount * 4 else {
            throw CookieReadError.parseFailed("truncated header")
        }
        var pageSizes: [Int] = []
        for i in 0..<pageCount {
            pageSizes.append(Int(readUInt32BE(data, at: 8 + i * 4)))
        }
        var pageStart = 8 + pageCount * 4

        var cookies: [ImportedCookie] = []
        for size in pageSizes {
            let pageEnd = pageStart + size
            guard pageEnd <= data.count else {
                throw CookieReadError.parseFailed("page overflow")
            }
            let page = data.subdata(in: pageStart..<pageEnd)
            try parsePage(page, into: &cookies)
            pageStart = pageEnd
        }
        return cookies.filter { CookieScope.matches(host: $0.domain) }
    }

    private func parsePage(_ page: Data, into cookies: inout [ImportedCookie]) throws {
        guard page.count >= 8 else { return }
        let cookieCount = Int(readUInt32LE(page, at: 4))
        guard page.count >= 8 + cookieCount * 4 else {
            throw CookieReadError.parseFailed("page header")
        }
        var offsets: [Int] = []
        for i in 0..<cookieCount {
            offsets.append(Int(readUInt32LE(page, at: 8 + i * 4)))
        }
        for off in offsets {
            if let c = parseCookie(page, at: off) {
                cookies.append(c)
            }
        }
    }

    private func parseCookie(_ page: Data, at off: Int) -> ImportedCookie? {
        guard off + 56 <= page.count else { return nil }
        let flags = readUInt32LE(page, at: off + 8)
        let urlOff = Int(readUInt32LE(page, at: off + 16))
        let nameOff = Int(readUInt32LE(page, at: off + 20))
        let pathOff = Int(readUInt32LE(page, at: off + 24))
        let valueOff = Int(readUInt32LE(page, at: off + 28))
        let expiresMac = readDoubleLE(page, at: off + 40)

        let macEpoch = Date(timeIntervalSince1970: 978307200)
        let expires = expiresMac > 0 ? macEpoch.addingTimeInterval(expiresMac) : nil

        guard let url = readCString(page, at: off + urlOff),
              let name = readCString(page, at: off + nameOff),
              let path = readCString(page, at: off + pathOff),
              let value = readCString(page, at: off + valueOff) else {
            return nil
        }

        return ImportedCookie(
            name: name, value: value,
            domain: url, path: path,
            expires: expires,
            isSecure: (flags & 1) != 0,
            isHTTPOnly: (flags & 4) != 0
        )
    }

    private func readUInt32BE(_ d: Data, at i: Int) -> UInt32 {
        let b = d.subdata(in: i..<i+4)
        return (UInt32(b[b.startIndex]) << 24) |
               (UInt32(b[b.startIndex + 1]) << 16) |
               (UInt32(b[b.startIndex + 2]) << 8) |
                UInt32(b[b.startIndex + 3])
    }

    private func readUInt32LE(_ d: Data, at i: Int) -> UInt32 {
        let b = d.subdata(in: i..<i+4)
        return  UInt32(b[b.startIndex]) |
               (UInt32(b[b.startIndex + 1]) << 8) |
               (UInt32(b[b.startIndex + 2]) << 16) |
               (UInt32(b[b.startIndex + 3]) << 24)
    }

    private func readDoubleLE(_ d: Data, at i: Int) -> Double {
        let b = d.subdata(in: i..<i+8)
        return b.withUnsafeBytes { ptr in ptr.load(as: Double.self) }
    }

    private func readCString(_ d: Data, at i: Int) -> String? {
        guard i < d.count else { return nil }
        var end = i
        while end < d.count && d[d.startIndex + end] != 0 { end += 1 }
        return String(data: d.subdata(in: i..<end), encoding: .utf8)
    }
}
