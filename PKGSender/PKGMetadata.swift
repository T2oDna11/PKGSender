import Foundation

struct PKGMetadata {
    enum Kind: String {
        case game = "GAME"
        case update = "UPDATE"
        case dlc = "DLC"
        case other = "PKG"
    }

    let title: String
    let titleID: String
    let contentID: String
    let version: String
    let category: String
    let kind: Kind
    let iconData: Data?
}

enum PKGMetadataParser {
    enum ParserError: LocalizedError {
        case invalidPKG
        case invalidEntryTable
        case truncated

        var errorDescription: String? {
            switch self {
            case .invalidPKG: return "Not a valid PS4 PKG"
            case .invalidEntryTable: return "Invalid PKG entry table"
            case .truncated: return "PKG ended before expected data"
            }
        }
    }

    private static let pkgMagic: UInt32 = 0x7F434E54
    private static let paramSFO: UInt32 = 0x1000
    private static let icon0PNG: UInt32 = 0x1200

    static func parse(url: URL) throws -> PKGMetadata {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try read(handle, offset: 0, count: 0x1000)
        guard be32(header, 0) == pkgMagic else { throw ParserError.invalidPKG }

        let entryCount = Int(be32(header, 0x10))
        let tableOffset = UInt64(be32(header, 0x18))
        guard entryCount > 0, entryCount <= 10_000 else { throw ParserError.invalidEntryTable }

        let contentIDHeader = ascii(header, offset: 0x40, count: 0x30)
        let tableSize = entryCount * 0x20
        guard tableSize <= 4 * 1024 * 1024 else { throw ParserError.invalidEntryTable }
        let table = try read(handle, offset: tableOffset, count: tableSize)

        var sfoData: Data?
        var iconData: Data?

        for i in 0..<entryCount {
            let base = i * 0x20
            let id = be32(table, base)
            let offset = UInt64(be32(table, base + 0x10))
            let length = Int(be32(table, base + 0x14))

            if id == paramSFO, length > 0, length <= 2 * 1024 * 1024 {
                sfoData = try read(handle, offset: offset, count: length)
            } else if id == icon0PNG, length > 0, length <= 8 * 1024 * 1024 {
                iconData = try read(handle, offset: offset, count: length)
            }
            if sfoData != nil && iconData != nil { break }
        }

        let sfo = sfoData.map(parseSFO) ?? [:]
        let contentID = nonEmpty(sfo["CONTENT_ID"], fallback: contentIDHeader)
        let titleID = nonEmpty(sfo["TITLE_ID"], fallback: extractTitleID(contentID))
        let category = (sfo["CATEGORY"] ?? "").lowercased()
        let filename = url.deletingPathExtension().lastPathComponent
        let title = nonEmpty(sfo["TITLE"], fallback: filename)
        let version = nonEmpty(sfo["APP_VER"], fallback: sfo["VERSION"] ?? "")

        let kind: PKGMetadata.Kind
        switch category {
        case "gd": kind = .game
        case "gp": kind = .update
        case "ac", "al": kind = .dlc
        default:
            let lower = url.lastPathComponent.lowercased()
            kind = (lower.contains("patch") || lower.contains("update")) ? .update : .other
        }

        return PKGMetadata(title: title, titleID: titleID, contentID: contentID,
                           version: version, category: category, kind: kind, iconData: iconData)
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw ParserError.truncated }
        return data
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            return (UInt32(p[offset]) << 24) | (UInt32(p[offset + 1]) << 16) |
                   (UInt32(p[offset + 2]) << 8) | UInt32(p[offset + 3])
        }
    }

    private static func le16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func ascii(_ data: Data, offset: Int, count: Int) -> String {
        guard offset < data.count else { return "" }
        let end = min(offset + count, data.count)
        let bytes = data[offset..<end]
        let trimmed = bytes.prefix { $0 != 0 }
        return String(bytes: trimmed, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseSFO(_ data: Data) -> [String: String] {
        guard data.count >= 20, le32(data, 0) == 0x46535000 else { return [:] }
        let keyTable = Int(le32(data, 8))
        let dataTable = Int(le32(data, 12))
        let count = Int(le32(data, 16))
        guard count >= 0, count <= 2048 else { return [:] }

        var result: [String: String] = [:]
        for i in 0..<count {
            let p = 20 + i * 16
            guard p + 16 <= data.count else { break }
            let keyOffset = Int(le16(data, p))
            let format = le16(data, p + 2)
            let length = Int(le32(data, p + 4))
            let valueOffset = Int(le32(data, p + 12))
            let keyPos = keyTable + keyOffset
            let valuePos = dataTable + valueOffset
            guard keyPos >= 0, keyPos < data.count, valuePos >= 0, valuePos < data.count, length >= 0 else { continue }
            let key = cString(data, at: keyPos, maxLength: 256)
            guard !key.isEmpty else { continue }
            let value: String
            if format == 0x0404, valuePos + 4 <= data.count {
                value = String(le32(data, valuePos))
            } else {
                value = cString(data, at: valuePos, maxLength: min(length, 4096))
            }
            result[key] = value
        }
        return result
    }

    private static func cString(_ data: Data, at position: Int, maxLength: Int) -> String {
        guard position >= 0, position < data.count, maxLength > 0 else { return "" }
        let limit = min(position + maxLength, data.count)
        var end = position
        while end < limit, data[end] != 0 { end += 1 }
        return String(data: data[position..<end], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func extractTitleID(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "CUSA\\d{5}", options: [.caseInsensitive]) else { return "" }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return "" }
        return String(text[r]).uppercased()
    }

    private static func nonEmpty(_ value: String?, fallback: String) -> String {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? fallback : v
    }
}
