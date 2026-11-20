import Compression
import Foundation

/// Pure-Swift PDF stream filter decoder & Flate encoder (ISO 32000-1 §7.4).
/// Supports FlateDecode, ASCIIHexDecode, ASCII85Decode, LZWDecode, and TIFF/PNG predictors.
enum PDFStreamFilter {

    /// Decode a PDF stream using its `/Filter` and optional `/DecodeParms` objects.
    static func decode(
        _ data: Data,
        filter: PDFObject?,
        decodeParms: PDFObject?
    ) throws -> Data {
        guard let filter, filter != .null else {
            return data
        }

        let filterNames: [String]
        let parmsList: [[String: PDFObject]?]

        switch filter {
        case .name(let name):
            filterNames = [name]
            parmsList = [decodeParms?.dictValue]
        case .array(let arr):
            filterNames = arr.compactMap { $0.nameValue }
            if case .array(let pArr) = decodeParms {
                parmsList = (0..<filterNames.count).map { idx in
                    idx < pArr.count ? pArr[idx].dictValue : nil
                }
            } else {
                parmsList = [decodeParms?.dictValue] + Array(repeating: nil, count: max(0, filterNames.count - 1))
            }
        default:
            throw PDFCoreError.unsupportedFilter("Unexpected /Filter type")
        }

        var current = data
        for (idx, name) in filterNames.enumerated() {
            let parms = idx < parmsList.count ? parmsList[idx] : nil
            current = try applySingleFilter(name, to: current, parms: parms)
        }
        return current
    }

    private static func applySingleFilter(
        _ name: String,
        to data: Data,
        parms: [String: PDFObject]?
    ) throws -> Data {
        switch name {
        case "FlateDecode", "Fl":
            let decoded = try flateDecode(data)
            return try applyPredictorIfNeeded(decoded, parms: parms)

        case "ASCIIHexDecode", "AHx":
            return asciiHexDecode(data)

        case "ASCII85Decode", "A85":
            return try ascii85Decode(data)

        case "LZWDecode", "LZW":
            let earlyChange = (parms?["EarlyChange"]?.intValue ?? 1) != 0
            let decoded = try lzwDecode(data, earlyChange: earlyChange)
            return try applyPredictorIfNeeded(decoded, parms: parms)

        case "Identity":
            return data

        default:
            throw PDFCoreError.unsupportedFilter(name)
        }
    }

    // MARK: - FlateDecode / FlateEncode (RFC 1950 zlib wrapper + RFC 1951 deflate via Compression)

    static func flateDecode(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        // Check for valid 2-byte RFC 1950 zlib header
        var deflateStart = 0
        if data.count >= 2 {
            let cmf = data[data.startIndex]
            let flg = data[data.startIndex + 1]
            let isDeflate = (cmf & 0x0F) == 8 && (cmf >> 4) <= 7
            let checksumOK = ((Int(cmf) << 8) + Int(flg)) % 31 == 0
            if isDeflate && checksumOK {
                deflateStart = ((flg & 0x20) != 0) ? 6 : 2
            }
        }

        if deflateStart > 0 && deflateStart < data.count {
            let stripped = data.subdata(in: (data.startIndex + deflateStart)..<data.endIndex)
            if let decoded = try? rawInflate(stripped) {
                return decoded
            }
        }

        // Fallback: try raw deflate directly
        return try rawInflate(data)
    }

    static func flateEncode(_ data: Data) throws -> Data {
        let deflated = try rawDeflate(data)
        var out = Data()
        out.reserveCapacity(2 + deflated.count + 4)
        // Standard zlib header (CMF=0x78, FLG=0x9C -> 32K window, default compression)
        out.append(0x78)
        out.append(0x9C)
        out.append(deflated)
        let adler = adler32(data)
        out.append(UInt8((adler >> 24) & 0xFF))
        out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF))
        out.append(UInt8(adler & 0xFF))
        return out
    }

    private static func rawInflate(_ data: Data) throws -> Data {
        return try processCompressionStream(data, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func rawDeflate(_ data: Data) throws -> Data {
        return try processCompressionStream(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    private static func processCompressionStream(
        _ input: Data,
        operation: compression_stream_operation
    ) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        let initStatus = compression_stream_init(stream, operation, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw PDFCoreError.streamDecodeFailed("compression_stream_init failed")
        }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 65536
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        var output = Data()

        try input.withUnsafeBytes { rawBuf in
            let srcBase = rawBuf.bindMemory(to: UInt8.self).baseAddress
            stream.pointee.src_ptr = srcBase ?? UnsafePointer<UInt8>(dstBuffer)
            stream.pointee.src_size = input.count

            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            while true {
                stream.pointee.dst_ptr = dstBuffer
                stream.pointee.dst_size = chunkSize

                let status = compression_stream_process(stream, flags)
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.pointee.src_size == 0 {
                        return
                    }
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw PDFCoreError.streamDecodeFailed("zlib stream processing error (\(status.rawValue))")
                }
            }
        }

        return output
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        let mod: UInt32 = 65521
        for b in data {
            s1 = (s1 + UInt32(b)) % mod
            s2 = (s2 + s1) % mod
        }
        return (s2 << 16) | s1
    }

    // MARK: - ASCIIHexDecode

    static func asciiHexDecode(_ data: Data) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 2)
        var highNibble: UInt8?

        for b in data {
            if b == 0x3E { break } // '>' EOD
            if PDFLexer.isWhitespace(b) { continue }
            if let v = PDFLexer.hexValue(b) {
                if let hi = highNibble {
                    out.append((hi << 4) | v)
                    highNibble = nil
                } else {
                    highNibble = v
                }
            }
        }
        if let hi = highNibble {
            out.append(hi << 4)
        }
        return Data(out)
    }

    // MARK: - ASCII85Decode

    static func ascii85Decode(_ data: Data) throws -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 4 / 5)

        var group: [UInt32] = []
        group.reserveCapacity(5)

        let bytes = Array(data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1

            if PDFLexer.isWhitespace(b) { continue }
            if b == 0x7E { // '~' -> expect '>' EOD
                break
            }
            if b == 0x7A { // 'z' -> four zero bytes
                guard group.isEmpty else {
                    throw PDFCoreError.streamDecodeFailed("Invalid 'z' inside ASCII85 group")
                }
                out.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            guard b >= 0x21 && b <= 0x75 else { // '!' .. 'u'
                throw PDFCoreError.streamDecodeFailed("Invalid ASCII85 byte \(b)")
            }
            group.append(UInt32(b - 0x21))
            if group.count == 5 {
                let value = decodeASCII85Group(group)
                out.append(UInt8((value >> 24) & 0xFF))
                out.append(UInt8((value >> 16) & 0xFF))
                out.append(UInt8((value >> 8) & 0xFF))
                out.append(UInt8(value & 0xFF))
                group.removeAll(keepingCapacity: true)
            }
        }

        if !group.isEmpty {
            let count = group.count
            guard count >= 2 else {
                throw PDFCoreError.streamDecodeFailed("Truncated 1-byte ASCII85 group")
            }
            while group.count < 5 {
                group.append(84) // pad with 'u'
            }
            let value = decodeASCII85Group(group)
            let emitCount = count - 1
            for shift in 0..<emitCount {
                out.append(UInt8((value >> (24 - shift * 8)) & 0xFF))
            }
        }

        return Data(out)
    }

    private static func decodeASCII85Group(_ g: [UInt32]) -> UInt32 {
        var acc: UInt64 = 0
        for d in g {
            acc = acc * 85 + UInt64(d)
        }
        return UInt32(truncatingIfNeeded: acc)
    }

    // MARK: - LZWDecode (ISO 32000-1 §7.4.4)

    static func lzwDecode(_ data: Data, earlyChange: Bool = true) throws -> Data {
        let bytes = Array(data)
        var bitPos = 0
        let totalBits = bytes.count * 8

        func readBits(_ width: Int) -> Int? {
            guard bitPos + width <= totalBits else { return nil }
            var val = 0
            for _ in 0..<width {
                let byteIdx = bitPos >> 3
                let bitIdx = 7 - (bitPos & 7)
                val = (val << 1) | Int((bytes[byteIdx] >> bitIdx) & 1)
                bitPos += 1
            }
            return val
        }

        let clearCode = 256
        let eodCode = 257

        var table: [[UInt8]] = []
        var codeSize = 9

        func resetTable() {
            table = (0..<256).map { [UInt8($0)] }
            table.append([]) // 256 Clear
            table.append([]) // 257 EOD
            codeSize = 9
        }

        resetTable()
        var out: [UInt8] = []
        var prevSeq: [UInt8]?

        while let code = readBits(codeSize) {
            if code == eodCode {
                break
            }
            if code == clearCode {
                resetTable()
                prevSeq = nil
                continue
            }

            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if code == table.count, let prev = prevSeq, let first = prev.first {
                entry = prev + [first]
            } else {
                throw PDFCoreError.streamDecodeFailed("Invalid LZW code \(code)")
            }

            out.append(contentsOf: entry)

            if let prev = prevSeq, let first = entry.first, table.count < 4096 {
                table.append(prev + [first])
                let threshold = (1 << codeSize) - (earlyChange ? 1 : 0)
                if table.count >= threshold && codeSize < 12 {
                    codeSize += 1
                }
            }

            prevSeq = entry
        }

        return Data(out)
    }

    // MARK: - Predictors (ISO 32000-1 §7.4.4.4)

    private static func applyPredictorIfNeeded(
        _ data: Data,
        parms: [String: PDFObject]?
    ) throws -> Data {
        let predictor = parms?["Predictor"]?.intValue ?? 1
        guard predictor > 1 else { return data }

        let colors = max(1, parms?["Colors"]?.intValue ?? 1)
        let bpc = max(1, parms?["BitsPerComponent"]?.intValue ?? 8)
        let columns = max(1, parms?["Columns"]?.intValue ?? 1)

        if predictor == 2 {
            return decodeTIFFPredictor(data, colors: colors, bitsPerComponent: bpc, columns: columns)
        } else if (10...15).contains(predictor) {
            return try decodePNGPredictor(data, colors: colors, bitsPerComponent: bpc, columns: columns)
        } else {
            throw PDFCoreError.streamDecodeFailed("Unsupported predictor \(predictor)")
        }
    }

    private static func decodeTIFFPredictor(
        _ data: Data,
        colors: Int,
        bitsPerComponent: Int,
        columns: Int
    ) -> Data {
        let rowBytes = (columns * colors * bitsPerComponent + 7) / 8
        guard rowBytes > 0 else { return data }
        var bytes = Array(data)
        let rowCount = bytes.count / rowBytes

        if bitsPerComponent == 8 {
            for row in 0..<rowCount {
                let rowStart = row * rowBytes
                if colors < rowBytes {
                    for i in colors..<rowBytes {
                        bytes[rowStart + i] = bytes[rowStart + i] &+ bytes[rowStart + i - colors]
                    }
                }
            }
            return Data(bytes)
        } else if bitsPerComponent == 16 {
            let stride = colors * 2
            for row in 0..<rowCount {
                let rowStart = row * rowBytes
                var i = stride
                while i + 1 < rowBytes {
                    let prev = (UInt16(bytes[rowStart + i - stride]) << 8) | UInt16(bytes[rowStart + i - stride + 1])
                    let curr = (UInt16(bytes[rowStart + i]) << 8) | UInt16(bytes[rowStart + i + 1])
                    let sum = curr &+ prev
                    bytes[rowStart + i] = UInt8((sum >> 8) & 0xFF)
                    bytes[rowStart + i + 1] = UInt8(sum & 0xFF)
                    i += 2
                }
            }
            return Data(bytes)
        } else {
            // Sub-byte components (1, 2, 4 bpc)
            let mask = (1 << bitsPerComponent) - 1
            let samplesPerRow = columns * colors
            var out = [UInt8](repeating: 0, count: bytes.count)
            for row in 0..<rowCount {
                let rowStart = row * rowBytes
                var prev = [Int](repeating: 0, count: colors)
                var bitOffset = 0
                for s in 0..<samplesPerRow {
                    let c = s % colors
                    let byteIdx = rowStart + (bitOffset >> 3)
                    let shift = 8 - bitsPerComponent - (bitOffset & 7)
                    let diff = (Int(bytes[byteIdx]) >> shift) & mask
                    let val = (prev[c] + diff) & mask
                    prev[c] = val
                    out[byteIdx] |= UInt8(val << shift)
                    bitOffset += bitsPerComponent
                }
            }
            return Data(out)
        }
    }

    private static func decodePNGPredictor(
        _ data: Data,
        colors: Int,
        bitsPerComponent: Int,
        columns: Int
    ) throws -> Data {
        let bpp = max(1, (colors * bitsPerComponent + 7) / 8)
        let rowBytes = (columns * colors * bitsPerComponent + 7) / 8
        let stride = rowBytes + 1
        guard rowBytes > 0, !data.isEmpty else { return Data() }

        let src = Array(data)
        var out: [UInt8] = []
        out.reserveCapacity((src.count / stride + 1) * rowBytes)

        var prevRow = [UInt8](repeating: 0, count: rowBytes)
        var offset = 0

        while offset < src.count {
            let filterType = src[offset]
            offset += 1
            let avail = min(rowBytes, src.count - offset)
            guard avail > 0 else { break }

            var currRow = [UInt8](repeating: 0, count: rowBytes)

            switch filterType {
            case 0: // None
                for i in 0..<avail {
                    currRow[i] = src[offset + i]
                }

            case 1: // Sub
                for i in 0..<avail {
                    let left: UInt8 = (i >= bpp) ? currRow[i - bpp] : 0
                    currRow[i] = src[offset + i] &+ left
                }

            case 2: // Up
                for i in 0..<avail {
                    currRow[i] = src[offset + i] &+ prevRow[i]
                }

            case 3: // Average
                for i in 0..<avail {
                    let left = (i >= bpp) ? Int(currRow[i - bpp]) : 0
                    let up = Int(prevRow[i])
                    currRow[i] = src[offset + i] &+ UInt8((left + up) >> 1)
                }

            case 4: // Paeth
                for i in 0..<avail {
                    let a = (i >= bpp) ? Int(currRow[i - bpp]) : 0
                    let b = Int(prevRow[i])
                    let c = (i >= bpp) ? Int(prevRow[i - bpp]) : 0
                    currRow[i] = src[offset + i] &+ paethPredictor(a, b, c)
                }

            default:
                throw PDFCoreError.streamDecodeFailed("Unknown PNG predictor filter type \(filterType)")
            }

            out.append(contentsOf: currRow[0..<avail])
            prevRow = currRow
            offset += avail
        }

        return Data(out)
    }

    @inline(__always)
    private static func paethPredictor(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc {
            return UInt8(a)
        } else if pb <= pc {
            return UInt8(b)
        } else {
            return UInt8(c)
        }
    }
}
