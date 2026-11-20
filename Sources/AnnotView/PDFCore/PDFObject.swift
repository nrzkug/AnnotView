import CoreGraphics
import Foundation

// MARK: - Errors

enum PDFCoreError: Error, LocalizedError, Sendable {
    case invalidPDF(String)
    case invalidXRef(String)
    case invalidObject(String)
    case unsupportedFilter(String)
    case streamDecodeFailed(String)
    case encryptionError(String)
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .invalidPDF(let msg): return "Invalid PDF: \(msg)"
        case .invalidXRef(let msg): return "Invalid PDF xref: \(msg)"
        case .invalidObject(let msg): return "Invalid PDF object: \(msg)"
        case .unsupportedFilter(let msg): return "Unsupported PDF stream filter: \(msg)"
        case .streamDecodeFailed(let msg): return "PDF stream decode failed: \(msg)"
        case .encryptionError(let msg): return "PDF encryption error: \(msg)"
        case .passwordRequired: return "PDF requires a user password."
        }
    }
}

// MARK: - Indirect Reference Key

struct PDFIndirectRef: Hashable, Sendable {
    let objNum: Int
    let genNum: Int

    init(objNum: Int, genNum: Int = 0) {
        self.objNum = objNum
        self.genNum = genNum
    }
}

// MARK: - COS Object Model

enum PDFObject: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case name(String) // Decoded name without leading "/"
    case string(Data) // Raw decoded bytes
    case array([PDFObject])
    case dict([String: PDFObject]) // Keys are decoded names without leading "/"
    case stream(dict: [String: PDFObject], data: Data)
    case indirectRef(objNum: Int, genNum: Int)

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return Int(exactly: v) }
        return nil
    }

    var int64Value: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    var realValue: Double? {
        switch self {
        case .real(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var nameValue: String? {
        if case .name(let v) = self { return v }
        return nil
    }

    var stringData: Data? {
        if case .string(let d) = self { return d }
        return nil
    }

    var textString: String? {
        if case .string(let d) = self { return PDFTextString.decode(d) }
        return nil
    }

    var arrayValue: [PDFObject]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var dictValue: [String: PDFObject]? {
        switch self {
        case .dict(let d): return d
        case .stream(let d, _): return d
        default: return nil
        }
    }

    var streamValue: (dict: [String: PDFObject], data: Data)? {
        if case .stream(let d, let data) = self { return (d, data) }
        return nil
    }

    var indirectRefValue: (objNum: Int, genNum: Int)? {
        if case .indirectRef(let o, let g) = self { return (o, g) }
        return nil
    }

    var cgRectValue: CGRect? {
        guard case .array(let arr) = self, arr.count == 4,
              let x0 = arr[0].realValue,
              let y0 = arr[1].realValue,
              let x1 = arr[2].realValue,
              let y1 = arr[3].realValue
        else { return nil }
        let minX = min(x0, x1)
        let minY = min(y0, y1)
        return CGRect(x: minX, y: minY, width: abs(x1 - x0), height: abs(y1 - y0))
    }

    subscript(key: String) -> PDFObject? {
        dictValue?[key]
    }
}

// MARK: - PDFTextString (PDFDocEncoding + UTF-16BE + UTF-8)

enum PDFTextString {
    /// Complete 256-entry ISO 32000-1 Table D.2 (PDFDocEncoding) -> Unicode scalar map.
    /// Undefined code points (0x7F, 0x9F, 0xAD) map to U+FFFD.
    private static let pdfDocEncodingTable: [UInt32] = [
        // 0x00 - 0x0F
        0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007,
        0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F,
        // 0x10 - 0x1F (0x18..0x1F are diacritics)
        0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017,
        0x02D8, 0x02C7, 0x02C6, 0x02D9, 0x02DD, 0x02DB, 0x02DA, 0x02DC,
        // 0x20 - 0x2F
        0x0020, 0x0021, 0x0022, 0x0023, 0x0024, 0x0025, 0x0026, 0x0027,
        0x0028, 0x0029, 0x002A, 0x002B, 0x002C, 0x002D, 0x002E, 0x002F,
        // 0x30 - 0x3F
        0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
        0x0038, 0x0039, 0x003A, 0x003B, 0x003C, 0x003D, 0x003E, 0x003F,
        // 0x40 - 0x4F
        0x0040, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
        0x0048, 0x0049, 0x004A, 0x004B, 0x004C, 0x004D, 0x004E, 0x004F,
        // 0x50 - 0x5F
        0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057,
        0x0058, 0x0059, 0x005A, 0x005B, 0x005C, 0x005D, 0x005E, 0x005F,
        // 0x60 - 0x6F
        0x0060, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
        0x0068, 0x0069, 0x006A, 0x006B, 0x006C, 0x006D, 0x006E, 0x006F,
        // 0x70 - 0x7F (0x7F undefined)
        0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077,
        0x0078, 0x0079, 0x007A, 0x007B, 0x007C, 0x007D, 0x007E, 0xFFFD,
        // 0x80 - 0x8F
        0x2022, 0x2020, 0x2021, 0x2026, 0x2014, 0x2013, 0x0192, 0x2044,
        0x2039, 0x203A, 0x2212, 0x2030, 0x201E, 0x201C, 0x201D, 0x2018,
        // 0x90 - 0x9F (0x9F undefined)
        0x2019, 0x201A, 0x2122, 0xFB01, 0xFB02, 0x0141, 0x0152, 0x0160,
        0x0178, 0x017D, 0x0131, 0x0142, 0x0153, 0x0161, 0x017E, 0xFFFD,
        // 0xA0 - 0xAF (0xA0 = Euro, 0xAD = undefined)
        0x20AC, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7,
        0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0xFFFD, 0x00AE, 0x00AF,
        // 0xB0 - 0xBF
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7,
        0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
        // 0xC0 - 0xCF
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7,
        0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        // 0xD0 - 0xDF
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7,
        0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        // 0xE0 - 0xEF
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7,
        0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        // 0xF0 - 0xFF
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7,
        0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF,
    ]

    private static let unicodeToPDFDocEncoding: [UInt32: UInt8] = {
        var map: [UInt32: UInt8] = [:]
        map.reserveCapacity(256)
        for (byte, scalar) in pdfDocEncodingTable.enumerated() where scalar != 0xFFFD {
            map[scalar] = UInt8(byte)
        }
        return map
    }()

    /// Decode a PDF text string (UTF-16BE with BOM, UTF-8 with BOM, UTF-16LE fallback, or PDFDocEncoding).
    static func decode(_ data: Data) -> String {
        let bytes = Array(data)
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            return decodeUTF16(bytes[2...], bigEndian: true)
        }
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return String(decoding: bytes[3...], as: UTF8.self)
        }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            return decodeUTF16(bytes[2...], bigEndian: false)
        }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for b in bytes {
            let code = pdfDocEncodingTable[Int(b)]
            if let scalar = Unicode.Scalar(code) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func decodeUTF16(_ slice: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(slice.count / 2)
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            let b0 = UInt16(slice[i])
            let b1 = UInt16(slice[i + 1])
            let unit = bigEndian ? ((b0 << 8) | b1) : ((b1 << 8) | b0)
            units.append(unit)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Encode a Swift `String` to PDF text string bytes.
    /// Uses ASCII / PDFDocEncoding when lossless (and not colliding with a BOM),
    /// otherwise UTF-16BE with `FE FF` BOM so CJK, emoji, and Unicode survive Acrobat & Preview.
    static func encode(_ string: String) -> Data {
        var pdfDocBytes: [UInt8] = []
        pdfDocBytes.reserveCapacity(string.unicodeScalars.count)
        var canUsePDFDoc = true

        for scalar in string.unicodeScalars {
            if let b = unicodeToPDFDocEncoding[scalar.value] {
                pdfDocBytes.append(b)
            } else {
                canUsePDFDoc = false
                break
            }
        }

        if canUsePDFDoc {
            // Avoid accidental BOM prefix in PDFDocEncoding bytes
            let collidesWithBOM =
                (pdfDocBytes.count >= 2 && pdfDocBytes[0] == 0xFE && pdfDocBytes[1] == 0xFF) ||
                (pdfDocBytes.count >= 2 && pdfDocBytes[0] == 0xFF && pdfDocBytes[1] == 0xFE) ||
                (pdfDocBytes.count >= 3 && pdfDocBytes[0] == 0xEF && pdfDocBytes[1] == 0xBB && pdfDocBytes[2] == 0xBF)
            if !collidesWithBOM {
                return Data(pdfDocBytes)
            }
        }

        var utf16Bytes: [UInt8] = [0xFE, 0xFF]
        utf16Bytes.reserveCapacity(2 + string.utf16.count * 2)
        for unit in string.utf16 {
            utf16Bytes.append(UInt8((unit >> 8) & 0xFF))
            utf16Bytes.append(UInt8(unit & 0xFF))
        }
        return Data(utf16Bytes)
    }
}

// MARK: - PDFDate

enum PDFDate {
    /// Parse a PDF date string (`D:YYYYMMDDHHmmSSOHH'mm'` and partial variants) to `Date`.
    static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("D:") || s.hasPrefix("d:") {
            s.removeFirst(2)
        }
        let chars = Array(s)
        var idx = 0

        func readDigits(_ count: Int) -> Int? {
            guard idx + count <= chars.count else { return nil }
            var val = 0
            for _ in 0..<count {
                guard let d = chars[idx].wholeNumberValue else { return nil }
                val = val * 10 + d
                idx += 1
            }
            return val
        }

        guard let year = readDigits(4) else { return nil }
        let month = readDigits(2) ?? 1
        let day = readDigits(2) ?? 1
        let hour = readDigits(2) ?? 0
        let minute = readDigits(2) ?? 0
        let second = readDigits(2) ?? 0

        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second)
        else { return nil }

        var tzOffsetSeconds = 0
        if idx < chars.count {
            let signChar = chars[idx]
            if signChar == "Z" || signChar == "z" {
                tzOffsetSeconds = 0
            } else if signChar == "+" || signChar == "-" {
                idx += 1
                let sign = (signChar == "+") ? 1 : -1
                let tzHour = readDigits(2) ?? 0
                if idx < chars.count && (chars[idx] == "'" || chars[idx] == ":") {
                    idx += 1
                }
                let tzMin = readDigits(2) ?? 0
                tzOffsetSeconds = sign * (tzHour * 3600 + tzMin * 60)
            }
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzOffsetSeconds) ?? TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = min(second, 59)
        return cal.date(from: comps)
    }

    /// Format a `Date` as UTC `D:YYYYMMDDHHmmSSZ`.
    static func format(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "D:%04d%02d%02d%02d%02d%02dZ",
            c.year ?? 1970,
            c.month ?? 1,
            c.day ?? 1,
            c.hour ?? 0,
            c.minute ?? 0,
            c.second ?? 0
        )
    }
}

// MARK: - PDFSerializer

enum PDFSerializer {
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    static func serialize(_ object: PDFObject) -> Data {
        var out = Data()
        appendSerialized(object, to: &out)
        return out
    }

    static func serializeIndirectObject(objNum: Int, genNum: Int, object: PDFObject) -> Data {
        var out = Data()
        out.append(contentsOf: "\(objNum) \(genNum) obj\n".utf8)
        appendSerialized(object, to: &out)
        out.append(contentsOf: "\nendobj\n".utf8)
        return out
    }

    /// Format a floating-point number cleanly for PDF: no `-0`, no scientific notation,
    /// and trailing fractional zeros trimmed.
    static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let v = (abs(value) < 1e-9) ? 0.0 : value
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        var formatted = String(format: "%.6f", v)
        if formatted.contains(".") {
            while formatted.last == "0" {
                formatted.removeLast()
            }
            if formatted.last == "." {
                formatted.removeLast()
            }
        }
        if formatted == "-0" || formatted.isEmpty {
            return "0"
        }
        return formatted
    }

    /// Encode a PDF Name with `/` prefix and `#XX` escaping for delimiters, `#`, whitespace, and non-ASCII bytes.
    static func encodeName(_ name: String) -> Data {
        var out = Data()
        out.reserveCapacity(name.utf8.count + 1)
        out.append(0x2F) // '/'
        for b in name.utf8 {
            if b < 0x21 || b > 0x7E || b == 0x23 || isDelimiter(b) {
                out.append(0x23) // '#'
                out.append(hexDigits[Int(b >> 4)])
                out.append(hexDigits[Int(b & 0x0F)])
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// Encode raw bytes as a PDF literal string `(...)`, escaping `\`, `(`, `)`, `\r`, `\n`,
    /// and using 3-digit octal escapes for control/non-ASCII bytes so output stays 7-bit clean.
    static func encodeLiteralString(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 2)
        out.append(0x28) // '('
        for b in data {
            switch b {
            case 0x5C: // '\'
                out.append(0x5C); out.append(0x5C)
            case 0x28: // '('
                out.append(0x5C); out.append(0x28)
            case 0x29: // ')'
                out.append(0x5C); out.append(0x29)
            case 0x0A: // '\n'
                out.append(0x5C); out.append(0x6E)
            case 0x0D: // '\r'
                out.append(0x5C); out.append(0x72)
            case 0x09: // '\t'
                out.append(0x5C); out.append(0x74)
            case 0x20...0x7E:
                out.append(b)
            default:
                out.append(0x5C)
                out.append(0x30 + ((b >> 6) & 0x07))
                out.append(0x30 + ((b >> 3) & 0x07))
                out.append(0x30 + (b & 0x07))
            }
        }
        out.append(0x29) // ')'
        return out
    }

    /// Encode raw bytes as a PDF hex string `<...>`.
    static func encodeHexString(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count * 2 + 2)
        out.append(0x3C) // '<'
        for b in data {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0F)])
        }
        out.append(0x3E) // '>'
        return out
    }

    private static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    private static func appendSerialized(_ object: PDFObject, to out: inout Data) {
        switch object {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let v):
            out.append(contentsOf: (v ? "true" : "false").utf8)
        case .int(let v):
            out.append(contentsOf: String(v).utf8)
        case .real(let v):
            out.append(contentsOf: formatNumber(v).utf8)
        case .name(let name):
            out.append(encodeName(name))
        case .string(let data):
            out.append(encodeLiteralString(data))
        case .array(let items):
            out.append(0x5B) // '['
            for (idx, item) in items.enumerated() {
                if idx > 0 { out.append(0x20) }
                appendSerialized(item, to: &out)
            }
            out.append(0x5D) // ']'
        case .dict(let dict):
            appendDict(dict, to: &out)
        case .stream(var dict, let data):
            dict["Length"] = .int(Int64(data.count))
            appendDict(dict, to: &out)
            out.append(contentsOf: "\nstream\n".utf8)
            out.append(data)
            out.append(contentsOf: "\nendstream".utf8)
        case .indirectRef(let objNum, let genNum):
            out.append(contentsOf: "\(objNum) \(genNum) R".utf8)
        }
    }

    private static func appendDict(_ dict: [String: PDFObject], to out: inout Data) {
        out.append(contentsOf: "<<".utf8)
        let sortedKeys = dict.keys.sorted()
        for key in sortedKeys {
            guard let val = dict[key] else { continue }
            out.append(0x20)
            out.append(encodeName(key))
            out.append(0x20)
            appendSerialized(val, to: &out)
        }
        out.append(contentsOf: " >>".utf8)
    }
}
