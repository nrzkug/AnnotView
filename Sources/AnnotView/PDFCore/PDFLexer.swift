import Foundation

/// Spec-compliant PDF byte scanner & COS object parser (ISO 32000-1 §7.2–§7.3).
struct PDFLexer {
    private let data: Data
    private let count: Int
    var position: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.count = data.count
        self.position = max(0, min(offset, data.count))
    }

    var isAtEnd: Bool { position >= count }

    // MARK: - Character Classification (ISO 32000-1 Tables 1 & 2)

    @inline(__always)
    static func isWhitespace(_ b: UInt8) -> Bool {
        switch b {
        case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x28, 0x29, // ( )
             0x3C, 0x3E, // < >
             0x5B, 0x5D, // [ ]
             0x7B, 0x7D, // { }
             0x2F,       // /
             0x25:       // %
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    @inline(__always)
    private func byte(at index: Int) -> UInt8 {
        data[data.startIndex + index]
    }

    @inline(__always)
    private func peek() -> UInt8? {
        guard position < count else { return nil }
        return byte(at: position)
    }

    @inline(__always)
    private func peek(ahead: Int) -> UInt8? {
        let idx = position + ahead
        guard idx >= 0 && idx < count else { return nil }
        return byte(at: idx)
    }

    // MARK: - Whitespace, Comments & Lines

    mutating func skipWhitespaceAndComments() {
        while position < count {
            let b = byte(at: position)
            if Self.isWhitespace(b) {
                position += 1
            } else if b == 0x25 { // '%'
                position += 1
                while position < count {
                    let c = byte(at: position)
                    position += 1
                    if c == 0x0A || c == 0x0D {
                        if c == 0x0D && position < count && byte(at: position) == 0x0A {
                            position += 1
                        }
                        break
                    }
                }
            } else {
                break
            }
        }
    }

    /// Reads a single non-delimiter token (keyword or number) without advancing past delimiters.
    mutating func readToken() -> String? {
        skipWhitespaceAndComments()
        guard position < count else { return nil }
        let start = position
        while position < count {
            let b = byte(at: position)
            if Self.isWhitespace(b) || Self.isDelimiter(b) {
                break
            }
            position += 1
        }
        guard position > start else { return nil }
        let slice = data[(data.startIndex + start)..<(data.startIndex + position)]
        return String(decoding: slice, as: UTF8.self)
    }

    mutating func readInt() -> Int? {
        let saved = position
        guard let token = readToken(), let val = Int(token) else {
            position = saved
            return nil
        }
        return val
    }

    /// Reads until the next CR/LF/CRLF (consuming the line terminator).
    mutating func readLine() -> String? {
        guard position < count else { return nil }
        let start = position
        while position < count {
            let b = byte(at: position)
            if b == 0x0A || b == 0x0D {
                let end = position
                position += 1
                if b == 0x0D && position < count && byte(at: position) == 0x0A {
                    position += 1
                }
                let slice = data[(data.startIndex + start)..<(data.startIndex + end)]
                return String(decoding: slice, as: UTF8.self)
            }
            position += 1
        }
        let slice = data[(data.startIndex + start)..<(data.startIndex + position)]
        return String(decoding: slice, as: UTF8.self)
    }

    // MARK: - Object Parsing

    mutating func parseObject(depth: Int = 0) -> PDFObject? {
        guard depth < 128 else { return nil }
        skipWhitespaceAndComments()
        guard let b = peek() else { return nil }

        switch b {
        case 0x28: // '(' literal string
            return .string(parseLiteralString())

        case 0x3C: // '<' hex string or '<<' dict
            if peek(ahead: 1) == 0x3C {
                return parseDict(depth: depth + 1)
            } else {
                return .string(parseHexString())
            }

        case 0x5B: // '[' array
            return parseArray(depth: depth + 1)

        case 0x2F: // '/' name
            return .name(parseName())

        case 0x5D, 0x3E: // unexpected ']' or '>'
            return nil

        default:
            return parseAtomOrIndirectRef()
        }
    }

    private mutating func parseAtomOrIndirectRef() -> PDFObject? {
        let saved = position
        guard let token = readToken() else { return nil }

        switch token {
        case "null":
            return .null
        case "true":
            return .bool(true)
        case "false":
            return .bool(false)
        default:
            break
        }

        // Check for numeric value
        if let intVal = parseStrictInt64(token) {
            // Look ahead for `N G R` indirect reference (only if N >= 0)
            if intVal >= 0 && intVal <= Int64(Int.max) {
                let afterFirst = position
                if let genToken = readToken(),
                   let genVal = parseStrictInt64(genToken),
                   genVal >= 0 && genVal <= Int64(Int.max),
                   let rToken = readToken(),
                   rToken == "R"
                {
                    return .indirectRef(objNum: Int(intVal), genNum: Int(genVal))
                }
                position = afterFirst
            }
            return .int(intVal)
        }

        if let doubleVal = parseStrictDouble(token) {
            return .real(doubleVal)
        }

        // Unknown keyword (e.g., "endobj", "endstream", "stream", "xref") — rewind so caller sees it
        position = saved
        return nil
    }

    private func parseStrictInt64(_ s: String) -> Int64? {
        guard !s.isEmpty else { return nil }
        var hasDigit = false
        for (i, ch) in s.utf8.enumerated() {
            if i == 0 && (ch == 0x2B || ch == 0x2D) { continue }
            if ch >= 0x30 && ch <= 0x39 {
                hasDigit = true
            } else {
                return nil
            }
        }
        guard hasDigit else { return nil }
        return Int64(s)
    }

    private func parseStrictDouble(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        var hasDigit = false
        var dotCount = 0
        for (i, ch) in s.utf8.enumerated() {
            if i == 0 && (ch == 0x2B || ch == 0x2D) { continue }
            if ch == 0x2E {
                dotCount += 1
                if dotCount > 1 { return nil }
            } else if ch >= 0x30 && ch <= 0x39 {
                hasDigit = true
            } else {
                return nil
            }
        }
        guard hasDigit else { return nil }
        return Double(s)
    }

    // MARK: - Literal String (...)

    private mutating func parseLiteralString() -> Data {
        // Consume '('
        position += 1
        var bytes: [UInt8] = []
        var parenDepth = 1

        while position < count && parenDepth > 0 {
            let b = byte(at: position)
            position += 1

            switch b {
            case 0x28: // '('
                parenDepth += 1
                bytes.append(b)

            case 0x29: // ')'
                parenDepth -= 1
                if parenDepth > 0 {
                    bytes.append(b)
                }

            case 0x5C: // '\'
                guard position < count else { break }
                let esc = byte(at: position)
                position += 1
                switch esc {
                case 0x6E: bytes.append(0x0A) // \n
                case 0x72: bytes.append(0x0D) // \r
                case 0x74: bytes.append(0x09) // \t
                case 0x62: bytes.append(0x08) // \b
                case 0x66: bytes.append(0x0C) // \f
                case 0x28: bytes.append(0x28) // \(
                case 0x29: bytes.append(0x29) // \)
                case 0x5C: bytes.append(0x5C) // \\
                case 0x0D: // \<CR> or \<CR><LF> line continuation
                    if position < count && byte(at: position) == 0x0A {
                        position += 1
                    }
                case 0x0A: // \<LF> line continuation
                    break
                case 0x30...0x37: // Octal \d, \dd, \ddd
                    var val = Int(esc - 0x30)
                    for _ in 0..<2 {
                        if position < count {
                            let next = byte(at: position)
                            if next >= 0x30 && next <= 0x37 {
                                val = (val << 3) | Int(next - 0x30)
                                position += 1
                            } else {
                                break
                            }
                        }
                    }
                    bytes.append(UInt8(val & 0xFF))
                default:
                    // Per ISO 32000-1 §7.3.4.2, unknown escape ignores the backslash
                    bytes.append(esc)
                }

            case 0x0D: // Unescaped CR or CRLF normalizes to LF (0x0A)
                if position < count && byte(at: position) == 0x0A {
                    position += 1
                }
                bytes.append(0x0A)

            default:
                bytes.append(b)
            }
        }

        return Data(bytes)
    }

    // MARK: - Hex String <...>

    private mutating func parseHexString() -> Data {
        // Consume '<'
        position += 1
        var bytes: [UInt8] = []
        var highNibble: UInt8?

        while position < count {
            let b = byte(at: position)
            position += 1
            if b == 0x3E { // '>'
                break
            }
            if Self.isWhitespace(b) {
                continue
            }
            if let v = Self.hexValue(b) {
                if let hi = highNibble {
                    bytes.append((hi << 4) | v)
                    highNibble = nil
                } else {
                    highNibble = v
                }
            }
        }

        // Odd number of hex digits: pad trailing 0
        if let hi = highNibble {
            bytes.append(hi << 4)
        }

        return Data(bytes)
    }

    // MARK: - Name /...

    private mutating func parseName() -> String {
        // Consume '/'
        position += 1
        var bytes: [UInt8] = []

        while position < count {
            let b = byte(at: position)
            if Self.isWhitespace(b) || Self.isDelimiter(b) {
                break
            }
            if b == 0x23, // '#'
               position + 2 < count,
               let hi = Self.hexValue(byte(at: position + 1)),
               let lo = Self.hexValue(byte(at: position + 2))
            {
                bytes.append((hi << 4) | lo)
                position += 3
            } else {
                bytes.append(b)
                position += 1
            }
        }

        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Array [...]

    private mutating func parseArray(depth: Int) -> PDFObject {
        // Consume '['
        position += 1
        var items: [PDFObject] = []

        while position < count {
            skipWhitespaceAndComments()
            guard let b = peek() else { break }
            if b == 0x5D { // ']'
                position += 1
                break
            }
            if let item = parseObject(depth: depth) {
                items.append(item)
            } else {
                // Skip unexpected token to avoid infinite loop
                if readToken() == nil {
                    position += 1
                }
            }
        }

        return .array(items)
    }

    // MARK: - Dictionary <<...>>

    private mutating func parseDict(depth: Int) -> PDFObject {
        // Consume '<<'
        position += 2
        var dict: [String: PDFObject] = [:]

        while position < count {
            skipWhitespaceAndComments()
            guard let b = peek() else { break }
            if b == 0x3E && peek(ahead: 1) == 0x3E { // '>>'
                position += 2
                break
            }
            guard b == 0x2F else {
                // Malformed entry; attempt recovery
                if readToken() == nil {
                    position += 1
                }
                continue
            }
            let key = parseName()
            skipWhitespaceAndComments()
            if peek() == 0x3E && peek(ahead: 1) == 0x3E {
                position += 2
                break
            }
            if let val = parseObject(depth: depth) {
                if val != .null {
                    dict[key] = val
                } else {
                    // Per ISO 32000-1 §7.3.7, a dictionary entry whose value is null is equivalent to absent,
                    // though storing .null is harmless if not present. Omit null entries cleanly.
                    dict.removeValue(forKey: key)
                }
            }
        }

        return .dict(dict)
    }

    // MARK: - Indirect Object (N G obj ... [stream ... endstream] ... endobj)

    mutating func parseIndirectObject(
        lengthResolver: ((PDFObject) -> Int?)? = nil
    ) -> (objNum: Int, genNum: Int, object: PDFObject)? {
        skipWhitespaceAndComments()
        guard let objNum = readInt(),
              let genNum = readInt(),
              let objKw = readToken(),
              objKw == "obj"
        else { return nil }

        skipWhitespaceAndComments()
        // Empty indirect object (`N G obj endobj`) -> `.null`
        let beforeVal = position
        if let kw = readToken(), kw == "endobj" {
            return (objNum, genNum, .null)
        }
        position = beforeVal

        guard var obj = parseObject() else {
            return (objNum, genNum, .null)
        }

        // Check for stream following a dictionary
        if case .dict(let dict) = obj {
            let afterDict = position
            if let kw = readToken(), kw == "stream" {
                let streamData = readStreamBody(dict: dict, lengthResolver: lengthResolver)
                obj = .stream(dict: dict, data: streamData)
            } else {
                position = afterDict
            }
        }

        // Consume optional trailing `endobj`
        let afterObj = position
        if let kw = readToken(), kw != "endobj" {
            position = afterObj
        }

        return (objNum, genNum, obj)
    }

    private mutating func readStreamBody(
        dict: [String: PDFObject],
        lengthResolver: ((PDFObject) -> Int?)?
    ) -> Data {
        // ISO 32000-1 §7.3.8.1: `stream` is followed by CRLF or LF (some generators emit CR only).
        if position < count {
            let b = byte(at: position)
            if b == 0x0D {
                position += 1
                if position < count && byte(at: position) == 0x0A {
                    position += 1
                }
            } else if b == 0x0A {
                position += 1
            }
        }

        let streamStart = position
        let endstreamBytes: [UInt8] = Array("endstream".utf8)

        // Try declared /Length first
        var resolvedLength: Int?
        if let lengthObj = dict["Length"] {
            if let directLen = lengthObj.intValue {
                resolvedLength = directLen
            } else if let resolver = lengthResolver {
                resolvedLength = resolver(lengthObj)
            }
        }

        if let len = resolvedLength, len >= 0, streamStart + len <= count {
            // Verify `endstream` appears right after streamStart + len (allowing whitespace/EOL)
            var checkPos = streamStart + len
            while checkPos < count && Self.isWhitespace(byte(at: checkPos)) {
                checkPos += 1
            }
            if matches(endstreamBytes, at: checkPos) {
                let body = data[(data.startIndex + streamStart)..<(data.startIndex + streamStart + len)]
                position = checkPos + endstreamBytes.count
                return Data(body)
            }
        }

        // Fallback: scan forward for `endstream`
        if let foundPos = Self.indexOf(endstreamBytes, in: data, from: streamStart) {
            var streamEnd = foundPos
            // Strip a single trailing EOL before `endstream`
            if streamEnd > streamStart && byte(at: streamEnd - 1) == 0x0A {
                streamEnd -= 1
                if streamEnd > streamStart && byte(at: streamEnd - 1) == 0x0D {
                    streamEnd -= 1
                }
            } else if streamEnd > streamStart && byte(at: streamEnd - 1) == 0x0D {
                streamEnd -= 1
            }
            let body = data[(data.startIndex + streamStart)..<(data.startIndex + streamEnd)]
            position = foundPos + endstreamBytes.count
            return Data(body)
        }

        // Last resort: if declared length was in bounds even without `endstream`, return it
        if let len = resolvedLength, len >= 0, streamStart + len <= count {
            let body = data[(data.startIndex + streamStart)..<(data.startIndex + streamStart + len)]
            position = streamStart + len
            return Data(body)
        }

        return Data()
    }

    private func matches(_ needle: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0 && offset + needle.count <= count else { return false }
        for i in 0..<needle.count {
            if byte(at: offset + i) != needle[i] { return false }
        }
        return true
    }

    // MARK: - Byte Search Utilities

    static func indexOf(_ needle: [UInt8], in data: Data, from start: Int = 0) -> Int? {
        guard !needle.isEmpty, start >= 0, start + needle.count <= data.count else { return nil }
        return data.withUnsafeBytes { rawBuf -> Int? in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let n = needle.count
            let limit = data.count - n
            let first = needle[0]
            var i = start
            while i <= limit {
                if base[i] == first {
                    var matched = true
                    var j = 1
                    while j < n {
                        if base[i + j] != needle[j] {
                            matched = false
                            break
                        }
                        j += 1
                    }
                    if matched { return i }
                }
                i += 1
            }
            return nil
        }
    }

    static func lastIndexOf(_ needle: [UInt8], in data: Data, searchLimit: Int? = nil) -> Int? {
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        let minIndex = max(0, searchLimit.map { data.count - $0 } ?? 0)
        return data.withUnsafeBytes { rawBuf -> Int? in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let n = needle.count
            let first = needle[0]
            var i = data.count - n
            while i >= minIndex {
                if base[i] == first {
                    var matched = true
                    var j = 1
                    while j < n {
                        if base[i + j] != needle[j] {
                            matched = false
                            break
                        }
                        j += 1
                    }
                    if matched { return i }
                }
                i -= 1
            }
            return nil
        }
    }
}
