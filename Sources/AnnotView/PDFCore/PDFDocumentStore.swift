import CoreGraphics
import Foundation

// MARK: - Page Record

struct PDFPageRecord: Sendable {
    let pageIndex: Int // 0-based
    let pageObjNum: Int
    let pageGenNum: Int
    let pageDict: [String: PDFObject]
    let mediaBox: CGRect
    let cropBox: CGRect
    let rotation: Int // normalized 0, 90, 180, 270
}

// MARK: - XRef Entry

private enum PDFXRefEntry: Sendable {
    case free(nextFree: Int, genNum: Int)
    case inUse(offset: Int, genNum: Int)
    case compressed(objStmNum: Int, index: Int)
}

// MARK: - PDFDocumentStore

/// Pure-Swift PDF document parser & random-access COS object store.
/// Supports classic xref tables, `/Prev` chains, hybrid `/XRefStm`, PDF 1.5+ `/Type /XRef` streams,
/// compressed `/Type /ObjStm` object streams, fallback xref repair, and transparent decryption via `PDFSecurityHandler`.
final class PDFDocumentStore: @unchecked Sendable {
    let rawData: Data
    let pdfHeaderOffset: Int
    let trailer: [String: PDFObject]
    let maxObjectNumber: Int
    let usesXRefStreams: Bool
    let lastStartXRef: Int
    let securityHandler: PDFSecurityHandler?
    let encryptObjNum: Int?

    private let xrefTable: [Int: PDFXRefEntry]
    private let lock = NSRecursiveLock()
    private var objectCache: [Int: PDFObject] = [:]
    private var objStmCache: [Int: [Int: PDFObject]] = [:]
    private var cachedPages: [PDFPageRecord]?
    private var resolvingObjects: Set<Int> = []

    convenience init(url: URL, password: String = "") throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data, password: password)
    }

    init(data: Data, password: String = "") throws {
        self.rawData = data

        // 1. Locate %PDF- header (allow leading garbage)
        let headerNeedle: [UInt8] = Array("%PDF-".utf8)
        guard let headerOffset = PDFLexer.indexOf(headerNeedle, in: data, from: 0) else {
            throw PDFCoreError.invalidPDF("Missing %PDF- header")
        }
        self.pdfHeaderOffset = headerOffset

        // 2. Locate startxref from EOF
        var parsedXRef: [Int: PDFXRefEntry] = [:]
        var parsedTrailer: [String: PDFObject] = [:]
        var detectedXRefStreams = false
        var detectedStartXRef = 0

        if let startXRef = Self.findStartXRef(in: data) {
            detectedStartXRef = startXRef
            let ok = Self.parseXRefChain(
                in: data,
                headerOffset: headerOffset,
                initialOffset: startXRef,
                xrefTable: &parsedXRef,
                trailer: &parsedTrailer,
                usesXRefStreams: &detectedXRefStreams
            )
            if !ok || parsedTrailer["Root"] == nil {
                // Attempt repair scan if xref was missing/corrupt
                Self.repairXRef(
                    in: data,
                    headerOffset: headerOffset,
                    xrefTable: &parsedXRef,
                    trailer: &parsedTrailer
                )
            }
        } else {
            Self.repairXRef(
                in: data,
                headerOffset: headerOffset,
                xrefTable: &parsedXRef,
                trailer: &parsedTrailer
            )
        }

        guard !parsedXRef.isEmpty else {
            throw PDFCoreError.invalidXRef("No objects found in PDF")
        }

        self.xrefTable = parsedXRef
        self.trailer = parsedTrailer
        self.usesXRefStreams = detectedXRefStreams
        self.lastStartXRef = detectedStartXRef

        let maxXRefKey = parsedXRef.keys.max() ?? 0
        let trailerSizeMax = max(0, (parsedTrailer["Size"]?.intValue ?? 0) - 1)
        self.maxObjectNumber = max(maxXRefKey, trailerSizeMax)

        // 3. Initialize encryption handler if /Encrypt is present
        if let encryptRef = parsedTrailer["Encrypt"] {
            let encObjNum = encryptRef.indirectRefValue?.objNum
            self.encryptObjNum = encObjNum

            let rawEncryptObj = Self.readRawObjectWithoutDecryption(
                encryptRef,
                in: data,
                headerOffset: headerOffset,
                xrefTable: parsedXRef
            )
            guard let rawEncryptDict = rawEncryptObj?.dictValue else {
                throw PDFCoreError.encryptionError("Unable to resolve /Encrypt dictionary")
            }

            // Resolve any indirect references inside /Encrypt (without decryption)
            let resolvedEncryptDict = Self.resolveDictWithoutDecryption(
                rawEncryptDict,
                in: data,
                headerOffset: headerOffset,
                xrefTable: parsedXRef,
                depth: 0
            )

            // Resolve trailer /ID first element (without decryption)
            var fileIDData: Data?
            if let idObj = parsedTrailer["ID"] {
                let resolvedID = Self.readRawObjectWithoutDecryption(
                    idObj,
                    in: data,
                    headerOffset: headerOffset,
                    xrefTable: parsedXRef
                )
                if case .array(let arr) = resolvedID, let first = arr.first?.stringData {
                    fileIDData = first
                }
            }

            self.securityHandler = try PDFSecurityHandler(
                encryptDict: resolvedEncryptDict,
                fileID: fileIDData,
                password: password
            )
        } else {
            self.encryptObjNum = nil
            self.securityHandler = nil
        }
    }

    // MARK: - Public Object Access

    func object(number objNum: Int, generation genNum: Int = 0) -> PDFObject? {
        guard objNum > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        if let cached = objectCache[objNum] {
            return cached
        }
        guard !resolvingObjects.contains(objNum) else {
            return nil // Cycle guard
        }
        guard let entry = xrefTable[objNum] else {
            return nil
        }

        resolvingObjects.insert(objNum)
        defer { resolvingObjects.remove(objNum) }

        let result: PDFObject?
        switch entry {
        case .free:
            result = nil

        case .inUse(let offset, let entryGen):
            let filePos = pdfHeaderOffset + offset
            guard filePos >= 0 && filePos < rawData.count else {
                return nil
            }
            var lexer = PDFLexer(data: rawData, offset: filePos)
            let parsed = lexer.parseIndirectObject { [weak self] lengthObj in
                guard let self else { return nil }
                return self.resolve(lengthObj)?.intValue
            }
            guard let parsed else { return nil }
            let actualGen = parsed.genNum
            let effectiveGen = (genNum == 0) ? actualGen : entryGen
            result = decryptIfNeeded(parsed.object, objNum: objNum, genNum: effectiveGen)

        case .compressed(let objStmNum, _):
            result = loadFromObjectStream(objStmNum: objStmNum, targetObjNum: objNum)
        }

        if let result {
            objectCache[objNum] = result
        }
        return result
    }

    func resolve(_ object: PDFObject?) -> PDFObject? {
        var current = object
        var visited: Set<Int> = []
        while case .indirectRef(let objNum, let genNum) = current {
            guard !visited.contains(objNum) else { return nil }
            visited.insert(objNum)
            current = self.object(number: objNum, generation: genNum)
        }
        return current
    }

    func decodedStreamData(for object: PDFObject) throws -> Data {
        guard let resolved = resolve(object),
              case .stream(let dict, let data) = resolved
        else {
            throw PDFCoreError.invalidObject("Expected stream object")
        }
        let filter = resolve(dict["Filter"])
        let decodeParms = resolve(dict["DecodeParms"])
        return try PDFStreamFilter.decode(data, filter: filter, decodeParms: decodeParms)
    }

    func catalog() -> [String: PDFObject]? {
        resolve(trailer["Root"])?.dictValue
    }

    func fileID() -> Data? {
        guard let resolved = resolve(trailer["ID"]),
              case .array(let arr) = resolved
        else { return nil }
        return arr.first?.stringData
    }

    // MARK: - Page Tree Traversal

    func pages() -> [PDFPageRecord] {
        lock.lock()
        if let cached = cachedPages {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var records: [PDFPageRecord] = []
        if let rootDict = catalog(), let pagesRef = rootDict["Pages"] {
            var visited: Set<Int> = []
            walkPageTree(
                nodeObj: pagesRef,
                inheritedMediaBox: nil,
                inheritedCropBox: nil,
                inheritedRotation: 0,
                visited: &visited,
                into: &records
            )
        }

        lock.lock()
        cachedPages = records
        lock.unlock()
        return records
    }

    private func walkPageTree(
        nodeObj: PDFObject,
        inheritedMediaBox: CGRect?,
        inheritedCropBox: CGRect?,
        inheritedRotation: Int,
        visited: inout Set<Int>,
        into records: inout [PDFPageRecord]
    ) {
        let objNum: Int
        let genNum: Int
        if let ref = nodeObj.indirectRefValue {
            guard !visited.contains(ref.objNum) else { return }
            visited.insert(ref.objNum)
            objNum = ref.objNum
            genNum = ref.genNum
        } else {
            objNum = 0
            genNum = 0
        }

        guard let nodeDict = resolve(nodeObj)?.dictValue else { return }

        let mediaBox = resolveRect(nodeDict["MediaBox"]) ?? inheritedMediaBox
        let cropBox = resolveRect(nodeDict["CropBox"]) ?? inheritedCropBox
        let rotation = resolve(nodeDict["Rotate"])?.intValue ?? inheritedRotation

        let nodeType = resolve(nodeDict["Type"])?.nameValue
        if nodeType == "Pages" || (nodeType != "Page" && nodeDict["Kids"] != nil) {
            if let kids = resolve(nodeDict["Kids"])?.arrayValue {
                for kid in kids {
                    walkPageTree(
                        nodeObj: kid,
                        inheritedMediaBox: mediaBox,
                        inheritedCropBox: cropBox,
                        inheritedRotation: rotation,
                        visited: &visited,
                        into: &records
                    )
                }
            }
        } else {
            let finalMediaBox = mediaBox ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            let finalCropBox = cropBox ?? finalMediaBox
            let normalizedRot = ((rotation % 360) + 360) % 360
            let snappedRot = (normalizedRot / 90) * 90
            records.append(
                PDFPageRecord(
                    pageIndex: records.count,
                    pageObjNum: objNum,
                    pageGenNum: genNum,
                    pageDict: nodeDict,
                    mediaBox: finalMediaBox,
                    cropBox: finalCropBox,
                    rotation: snappedRot
                )
            )
        }
    }

    private func resolveRect(_ obj: PDFObject?) -> CGRect? {
        guard let arr = resolve(obj)?.arrayValue, arr.count == 4 else { return nil }
        guard let x0 = resolve(arr[0])?.realValue,
              let y0 = resolve(arr[1])?.realValue,
              let x1 = resolve(arr[2])?.realValue,
              let y1 = resolve(arr[3])?.realValue
        else { return nil }
        return CGRect(
            x: min(x0, x1),
            y: min(y0, y1),
            width: abs(x1 - x0),
            height: abs(y1 - y0)
        )
    }

    // MARK: - Compressed Object Streams (/Type /ObjStm)

    private func loadFromObjectStream(objStmNum: Int, targetObjNum: Int) -> PDFObject? {
        if let cachedStreamMap = objStmCache[objStmNum] {
            return cachedStreamMap[targetObjNum]
        }

        guard let stmObj = object(number: objStmNum),
              case .stream(let dict, let rawStreamData) = stmObj
        else { return nil }

        let filter = resolve(dict["Filter"])
        let decodeParms = resolve(dict["DecodeParms"])
        guard let decoded = try? PDFStreamFilter.decode(rawStreamData, filter: filter, decodeParms: decodeParms) else {
            return nil
        }

        let n = resolve(dict["N"])?.intValue ?? 0
        let first = resolve(dict["First"])?.intValue ?? 0
        guard n > 0, first >= 0, first <= decoded.count else { return nil }

        var headerLexer = PDFLexer(data: decoded, offset: 0)
        var pairs: [(objNum: Int, relOffset: Int)] = []
        pairs.reserveCapacity(n)
        for _ in 0..<n {
            guard let num = headerLexer.readInt(),
                  let relOff = headerLexer.readInt()
            else { break }
            pairs.append((num, relOff))
        }

        var map: [Int: PDFObject] = [:]
        map.reserveCapacity(pairs.count)
        for pair in pairs {
            let absOffset = first + pair.relOffset
            guard absOffset >= first && absOffset < decoded.count else { continue }
            var objLexer = PDFLexer(data: decoded, offset: absOffset)
            if let parsed = objLexer.parseObject() {
                map[pair.objNum] = parsed
            }
        }

        objStmCache[objStmNum] = map
        return map[targetObjNum]
    }

    // MARK: - Decryption Helper

    private func decryptIfNeeded(_ object: PDFObject, objNum: Int, genNum: Int) -> PDFObject {
        guard let handler = securityHandler else { return object }
        // Never decrypt /Encrypt dictionary itself
        if let encNum = encryptObjNum, objNum == encNum {
            return object
        }
        // Never decrypt /Type /XRef streams
        if case .stream(let dict, _) = object, dict["Type"]?.nameValue == "XRef" {
            return object
        }
        return decryptObjectRecursively(object, handler: handler, objNum: objNum, genNum: genNum)
    }

    private func decryptObjectRecursively(
        _ object: PDFObject,
        handler: PDFSecurityHandler,
        objNum: Int,
        genNum: Int
    ) -> PDFObject {
        switch object {
        case .string(let data):
            return .string(handler.decryptString(data, objNum: objNum, genNum: genNum))

        case .array(let arr):
            return .array(arr.map { decryptObjectRecursively($0, handler: handler, objNum: objNum, genNum: genNum) })

        case .dict(let dict):
            var out: [String: PDFObject] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = decryptObjectRecursively(v, handler: handler, objNum: objNum, genNum: genNum)
            }
            return .dict(out)

        case .stream(let dict, let data):
            var outDict: [String: PDFObject] = [:]
            outDict.reserveCapacity(dict.count)
            for (k, v) in dict {
                outDict[k] = decryptObjectRecursively(v, handler: handler, objNum: objNum, genNum: genNum)
            }

            // Skip decrypting stream body if /Type /Metadata and EncryptMetadata == false
            let isMetadata = (dict["Type"]?.nameValue == "Metadata")
            if isMetadata && !handler.encryptMetadata {
                return .stream(dict: outDict, data: data)
            }

            // Skip decrypting stream body if stream specifies /Filter /Crypt with /Name /Identity
            if isIdentityCryptStream(dict) {
                return .stream(dict: outDict, data: data)
            }

            let decryptedData = handler.decryptStream(data, objNum: objNum, genNum: genNum)
            return .stream(dict: outDict, data: decryptedData)

        default:
            return object
        }
    }

    private func isIdentityCryptStream(_ dict: [String: PDFObject]) -> Bool {
        if let filterName = dict["Filter"]?.nameValue, filterName == "Crypt" {
            let name = dict["DecodeParms"]?.dictValue?["Name"]?.nameValue ?? "Identity"
            return name == "Identity"
        }
        if case .array(let filters) = dict["Filter"], let first = filters.first?.nameValue, first == "Crypt" {
            if case .array(let parms) = dict["DecodeParms"], let firstParm = parms.first?.dictValue {
                return (firstParm["Name"]?.nameValue ?? "Identity") == "Identity"
            }
            return true
        }
        return false
    }

    // MARK: - XRef & Trailer Parsing (Static)

    private static func findStartXRef(in data: Data) -> Int? {
        let needle: [UInt8] = Array("startxref".utf8)
        let pos = PDFLexer.lastIndexOf(needle, in: data, searchLimit: 4096)
            ?? PDFLexer.lastIndexOf(needle, in: data, searchLimit: nil)
        guard let pos else { return nil }
        var lexer = PDFLexer(data: data, offset: pos + needle.count)
        return lexer.readInt()
    }

    private static func parseXRefChain(
        in data: Data,
        headerOffset: Int,
        initialOffset: Int,
        xrefTable: inout [Int: PDFXRefEntry],
        trailer: inout [String: PDFObject],
        usesXRefStreams: inout Bool
    ) -> Bool {
        var visitedOffsets: Set<Int> = []
        var nextOffset: Int? = initialOffset
        var isFirstSection = true
        var parsedAny = false

        while let offset = nextOffset {
            guard offset >= 0, !visitedOffsets.contains(offset) else { break }
            visitedOffsets.insert(offset)

            let filePos = headerOffset + offset
            guard filePos >= 0 && filePos < data.count else { break }

            var sectionEntries: [Int: PDFXRefEntry] = [:]
            var sectionTrailer: [String: PDFObject] = [:]

            var lexer = PDFLexer(data: data, offset: filePos)
            lexer.skipWhitespaceAndComments()
            let savedPos = lexer.position
            let firstToken = lexer.readToken()

            if firstToken == "xref" {
                guard parseClassicXRefSection(lexer: &lexer, entries: &sectionEntries, trailer: &sectionTrailer) else {
                    break
                }
                parsedAny = true

                // Hybrid-reference PDF: /XRefStm in the same trailer supplements/overrides free entries
                if let xrefStmOffset = sectionTrailer["XRefStm"]?.intValue,
                   !visitedOffsets.contains(xrefStmOffset)
                {
                    visitedOffsets.insert(xrefStmOffset)
                    var stmEntries: [Int: PDFXRefEntry] = [:]
                    var stmTrailer: [String: PDFObject] = [:]
                    if parseXRefStreamSection(
                        in: data,
                        headerOffset: headerOffset,
                        offset: xrefStmOffset,
                        entries: &stmEntries,
                        trailer: &stmTrailer
                    ) {
                        for (objNum, entry) in stmEntries {
                            if let existing = sectionEntries[objNum] {
                                if case .free = existing {
                                    sectionEntries[objNum] = entry
                                }
                            } else {
                                sectionEntries[objNum] = entry
                            }
                        }
                    }
                }
            } else {
                lexer.position = savedPos
                guard parseXRefStreamSection(
                    in: data,
                    headerOffset: headerOffset,
                    offset: offset,
                    entries: &sectionEntries,
                    trailer: &sectionTrailer
                ) else {
                    break
                }
                parsedAny = true
                if isFirstSection {
                    usesXRefStreams = true
                }
            }

            // Merge into main xrefTable (newer sections win)
            for (objNum, entry) in sectionEntries where xrefTable[objNum] == nil {
                xrefTable[objNum] = entry
            }

            // Merge trailer keys (newer sections win)
            for (k, v) in sectionTrailer where trailer[k] == nil {
                trailer[k] = v
            }

            isFirstSection = false
            nextOffset = sectionTrailer["Prev"]?.intValue
        }

        return parsedAny
    }

    private static func parseClassicXRefSection(
        lexer: inout PDFLexer,
        entries: inout [Int: PDFXRefEntry],
        trailer: inout [String: PDFObject]
    ) -> Bool {
        while !lexer.isAtEnd {
            lexer.skipWhitespaceAndComments()
            let saved = lexer.position
            guard let tok = lexer.readToken() else { break }

            if tok == "trailer" {
                if let dict = lexer.parseObject()?.dictValue {
                    trailer = dict
                    return true
                }
                return false
            }

            // Subsection header: startObjNum count
            guard let startObj = Int(tok),
                  let count = lexer.readInt(),
                  startObj >= 0, count >= 0
            else {
                lexer.position = saved
                return false
            }

            for i in 0..<count {
                guard let field1 = lexer.readInt(),
                      let field2 = lexer.readInt(),
                      let flag = lexer.readToken()
                else {
                    return false
                }
                let objNum = startObj + i
                if flag == "n" {
                    if entries[objNum] == nil {
                        entries[objNum] = .inUse(offset: field1, genNum: field2)
                    }
                } else if flag == "f" {
                    if entries[objNum] == nil {
                        entries[objNum] = .free(nextFree: field1, genNum: field2)
                    }
                }
            }
        }
        return false
    }

    private static func parseXRefStreamSection(
        in data: Data,
        headerOffset: Int,
        offset: Int,
        entries: inout [Int: PDFXRefEntry],
        trailer: inout [String: PDFObject]
    ) -> Bool {
        let filePos = headerOffset + offset
        guard filePos >= 0 && filePos < data.count else { return false }

        var lexer = PDFLexer(data: data, offset: filePos)
        guard let parsed = lexer.parseIndirectObject(),
              case .stream(let dict, let rawStreamData) = parsed.object,
              dict["Type"]?.nameValue == "XRef"
        else { return false }

        guard let decoded = try? PDFStreamFilter.decode(
            rawStreamData,
            filter: dict["Filter"],
            decodeParms: dict["DecodeParms"]
        ) else { return false }

        guard let wArr = dict["W"]?.arrayValue, wArr.count == 3,
              let w0 = wArr[0].intValue,
              let w1 = wArr[1].intValue,
              let w2 = wArr[2].intValue,
              w0 >= 0, w1 >= 0, w2 >= 0
        else { return false }

        let entrySize = w0 + w1 + w2
        guard entrySize > 0 else { return false }

        let size = dict["Size"]?.intValue ?? 0
        var indexRanges: [(start: Int, count: Int)] = []
        if let idxArr = dict["Index"]?.arrayValue, idxArr.count >= 2 {
            var i = 0
            while i + 1 < idxArr.count {
                if let s = idxArr[i].intValue, let c = idxArr[i + 1].intValue {
                    indexRanges.append((s, c))
                }
                i += 2
            }
        } else if size > 0 {
            indexRanges.append((0, size))
        }

        let bytes = Array(decoded)
        var cursor = 0

        func readBEInt(_ width: Int) -> Int {
            guard width > 0 else { return 0 }
            var val = 0
            for _ in 0..<width {
                if cursor < bytes.count {
                    val = (val << 8) | Int(bytes[cursor])
                    cursor += 1
                }
            }
            return val
        }

        for range in indexRanges {
            for i in 0..<range.count {
                guard cursor + entrySize <= bytes.count else { break }
                let type = (w0 == 0) ? 1 : readBEInt(w0)
                let f2 = readBEInt(w1)
                let f3 = readBEInt(w2)
                let objNum = range.start + i
                guard entries[objNum] == nil else { continue }

                switch type {
                case 0:
                    entries[objNum] = .free(nextFree: f2, genNum: f3)
                case 1:
                    entries[objNum] = .inUse(offset: f2, genNum: f3)
                case 2:
                    entries[objNum] = .compressed(objStmNum: f2, index: f3)
                default:
                    break
                }
            }
        }

        // Copy trailer-relevant keys from XRef stream dictionary
        for key in ["Root", "Info", "ID", "Encrypt", "Size", "Prev"] {
            if let v = dict[key] {
                trailer[key] = v
            }
        }

        return true
    }

    // MARK: - Fallback XRef Repair Scanner

    private static func repairXRef(
        in data: Data,
        headerOffset: Int,
        xrefTable: inout [Int: PDFXRefEntry],
        trailer: inout [String: PDFObject]
    ) {
        let bytes = Array(data)
        let n = bytes.count
        var i = headerOffset
        var catalogRef: (Int, Int)?

        while i < n {
            // Skip to start of a line or after whitespace
            if i == headerOffset || bytes[i - 1] == 0x0A || bytes[i - 1] == 0x0D || bytes[i - 1] == 0x20 {
                // Check for `N G obj`
                if bytes[i] >= 0x30 && bytes[i] <= 0x39 {
                    var lexer = PDFLexer(data: data, offset: i)
                    if let objNum = lexer.readInt(),
                       let genNum = lexer.readInt(),
                       let kw = lexer.readToken(),
                       kw == "obj",
                       objNum > 0, genNum >= 0
                    {
                        xrefTable[objNum] = .inUse(offset: i - headerOffset, genNum: genNum)
                        // Peek if this object is the /Catalog or an /XRef stream
                        if let parsed = lexer.parseObject() {
                            if let d = parsed.dictValue {
                                let t = d["Type"]?.nameValue
                                if t == "Catalog" {
                                    catalogRef = (objNum, genNum)
                                } else if t == "XRef" {
                                    for key in ["Root", "Info", "ID", "Encrypt", "Size"] {
                                        if let v = d[key] {
                                            trailer[key] = v
                                        }
                                    }
                                }
                            }
                        }
                        i = max(i + 1, lexer.position)
                        continue
                    }
                } else if bytes[i] == 0x74 { // 't' -> check for "trailer"
                    if i + 7 <= n,
                       bytes[i] == 0x74, bytes[i + 1] == 0x72, bytes[i + 2] == 0x61,
                       bytes[i + 3] == 0x69, bytes[i + 4] == 0x6C, bytes[i + 5] == 0x65,
                       bytes[i + 6] == 0x72
                    {
                        var lexer = PDFLexer(data: data, offset: i + 7)
                        if let dict = lexer.parseObject()?.dictValue {
                            for (k, v) in dict {
                                trailer[k] = v
                            }
                            i = max(i + 7, lexer.position)
                            continue
                        }
                    }
                }
            }
            i += 1
        }

        if trailer["Root"] == nil, let (cObj, cGen) = catalogRef {
            trailer["Root"] = .indirectRef(objNum: cObj, genNum: cGen)
        }
    }

    // MARK: - Pre-Decryption Raw Resolution (for /Encrypt and /ID during init)

    private static func readRawObjectWithoutDecryption(
        _ obj: PDFObject,
        in data: Data,
        headerOffset: Int,
        xrefTable: [Int: PDFXRefEntry]
    ) -> PDFObject? {
        var current: PDFObject? = obj
        var visited: Set<Int> = []
        while case .indirectRef(let objNum, _) = current {
            guard !visited.contains(objNum) else { return nil }
            visited.insert(objNum)
            guard case .inUse(let offset, _) = xrefTable[objNum] else { return nil }
            let filePos = headerOffset + offset
            guard filePos >= 0 && filePos < data.count else { return nil }
            var lexer = PDFLexer(data: data, offset: filePos)
            current = lexer.parseIndirectObject()?.object
        }
        return current
    }

    private static func resolveDictWithoutDecryption(
        _ dict: [String: PDFObject],
        in data: Data,
        headerOffset: Int,
        xrefTable: [Int: PDFXRefEntry],
        depth: Int
    ) -> [String: PDFObject] {
        guard depth < 8 else { return dict }
        var out: [String: PDFObject] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            let resolved = readRawObjectWithoutDecryption(v, in: data, headerOffset: headerOffset, xrefTable: xrefTable) ?? v
            if case .dict(let sub) = resolved {
                out[k] = .dict(
                    resolveDictWithoutDecryption(sub, in: data, headerOffset: headerOffset, xrefTable: xrefTable, depth: depth + 1)
                )
            } else {
                out[k] = resolved
            }
        }
        return out
    }
}
