import Foundation

public enum LineEnding: String, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var characters: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// A text file decoded for editing. `text` always uses "\n" line endings;
/// the original line ending and encoding are kept so saving writes them back.
public struct TextFile: Equatable {
    public var text: String
    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding
    public var isBinary: Bool
    public var exists: Bool

    public static let empty = TextFile(text: "", encoding: .utf8, hasBOM: false, lineEnding: .lf, isBinary: false, exists: false)

    public var encodingName: String {
        switch encoding {
        case .utf8: return hasBOM ? "UTF-8 (BOM)" : "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .shiftJIS: return "Shift_JIS"
        case .japaneseEUC: return "EUC-JP"
        case .isoLatin1: return "ISO-8859-1"
        default: return String.localizedName(of: encoding)
        }
    }

    /// Reads a file. A missing file is returned as an empty file with `exists == false`.
    public static func load(_ url: URL) throws -> TextFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return decode(try Data(contentsOf: url))
    }

    /// Decodes with a given encoding instead of detecting it (for "Reopen with Encoding").
    /// Returns nil when the data is not valid in that encoding.
    public static func decode(_ data: Data, as encoding: String.Encoding) -> TextFile? {
        var file = TextFile.empty
        file.exists = true
        file.encoding = encoding
        var body = data
        let boms: [(String.Encoding, [UInt8])] = [(.utf8, [0xEF, 0xBB, 0xBF]), (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF])]
        if let bom = boms.first(where: { $0.0 == encoding && data.starts(with: $0.1) }) {
            file.hasBOM = true
            body = data.dropFirst(bom.1.count)
        }
        guard let raw = String(data: body, encoding: encoding) else { return nil }
        file.lineEnding = detectLineEnding(raw)
        file.text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return file
    }

    /// Encodings offered in the Encoding menus.
    public static let menuEncodings: [(encoding: String.Encoding, bom: Bool, name: String)] = [
        (.utf8, false, "UTF-8"), (.utf8, true, "UTF-8 (BOM)"), (.utf16LittleEndian, true, "UTF-16 LE"),
        (.utf16BigEndian, true, "UTF-16 BE"), (.shiftJIS, false, "Shift_JIS"), (.japaneseEUC, false, "EUC-JP"),
        (.isoLatin1, false, "ISO-8859-1"),
    ]

    public static func decode(_ data: Data) -> TextFile {
        var file = TextFile.empty
        file.exists = true
        var body = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            file.encoding = .utf8; file.hasBOM = true; body = data.dropFirst(3)
        } else if data.starts(with: [0xFF, 0xFE]) {
            file.encoding = .utf16LittleEndian; file.hasBOM = true; body = data.dropFirst(2)
        } else if data.starts(with: [0xFE, 0xFF]) {
            file.encoding = .utf16BigEndian; file.hasBOM = true; body = data.dropFirst(2)
        } else if looksBinary(data) {
            file.isBinary = true
            return file
        }

        var decoded: String?
        if file.hasBOM {
            decoded = String(data: body, encoding: file.encoding)
        } else {
            for candidate in [String.Encoding.utf8, .shiftJIS, .japaneseEUC, .isoLatin1] {
                if let s = String(data: body, encoding: candidate) {
                    decoded = s
                    file.encoding = candidate
                    break
                }
            }
        }
        guard let raw = decoded else {
            file.isBinary = true
            return file
        }
        file.lineEnding = detectLineEnding(raw)
        file.text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return file
    }

    /// Encodes `text` with this file's encoding and line ending. Returns nil when the
    /// text contains characters the encoding cannot represent.
    public func encode(_ text: String) -> Data? {
        let converted = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.characters)
        guard let body = converted.data(using: encoding, allowLossyConversion: false) else { return nil }
        guard hasBOM else { return body }
        switch encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF]) + body
        case .utf16LittleEndian: return Data([0xFF, 0xFE]) + body
        case .utf16BigEndian: return Data([0xFE, 0xFF]) + body
        default: return body
        }
    }

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    static func detectLineEnding(_ s: String) -> LineEnding {
        // String treats "\r\n" as one Character, so scan UTF-8 bytes instead.
        let bytes = Array(s.utf8.prefix(1_000_000))
        for (i, byte) in bytes.enumerated() {
            if byte == 0x0A { return .lf }
            if byte == 0x0D { return i + 1 < bytes.count && bytes[i + 1] == 0x0A ? .crlf : .cr }
        }
        return .lf
    }
}
