import Darwin
import Foundation

/// Appends PDF Incremental Updates (ISO 32000-1 §7.5.6) to an existing `PDFDocumentStore`
/// without rewriting untouched objects, preserving original xref style (classic xref table
/// or PDF 1.5+ `/Type /XRef` stream) and encryption when present.
final class PDFIncrementalWriter {
    enum WriterError: LocalizedError {
        case emptyOutput
        case invalidObjectNumber(Int)

        var errorDescription: String? {
            switch self {
            case .emptyOutput:
                "Incremental PDF writer produced empty output."
            case .invalidObjectNumber(let num):
                "Invalid PDF object number: \(num)."
            }
        }
    }

    let store: PDFDocumentStore
    private var nextObjNum: Int
    private var updatedObjects: [Int: (genNum: Int, object: PDFObject)] = [:]

    init(store: PDFDocumentStore) {
        self.store = store
        let trailerSize = store.trailer["Size"]?.intValue ?? 0
        self.nextObjNum = max(store.maxObjectNumber + 1, trailerSize)
        if self.nextObjNum < 1 {
            self.nextObjNum = 1
        }
    }

    // MARK: - Object Allocation & Mutation

    /// Allocates a new indirect object number and registers `object` for emission.
    @discardableResult
    func allocateObject(_ object: PDFObject) -> PDFIndirectRef {
        let objNum = nextObjNum
        nextObjNum += 1
        updatedObjects[objNum] = (genNum: 0, object: object)
        return PDFIndirectRef(objNum: objNum, genNum: 0)
    }

    /// Reserves a new indirect object number without setting its body yet.
    func reserveObjectNumber() -> Int {
        let objNum = nextObjNum
        nextObjNum += 1
        return objNum
    }

    /// Registers or replaces an indirect object in the incremental update.
    func setObject(_ object: PDFObject, number objNum: Int, generation genNum: Int = 0) {
        updatedObjects[objNum] = (genNum: genNum, object: object)
        if objNum >= nextObjNum {
            nextObjNum = objNum + 1
        }
    }

    /// Returns the latest version of an indirect object (pending update or original store).
    func currentObject(number objNum: Int, generation genNum: Int = 0) -> PDFObject? {
        if let pending = updatedObjects[objNum] {
            return pending.object
        }
        return store.object(number: objNum, generation: genNum)
    }

    /// Resolves indirect references against both pending updates and the original store.
    func resolve(_ object: PDFObject?) -> PDFObject? {
        var current = object
        var depth = 0
        while case let .indirectRef(objNum, genNum) = current, depth < 32 {
            current = currentObject(number: objNum, generation: genNum)
            depth += 1
        }
        return current
    }

    // MARK: - Page /Annots Helpers

    /// Returns the current `/Annots` array entries for `page`, reflecting any prior mutations
    /// in this writer session.
    func pageAnnots(for page: PDFPageRecord) -> [PDFObject] {
        guard let pageDict = currentObject(number: page.pageObjNum, generation: page.pageGenNum)?.dictValue else {
            return []
        }
        guard let annotsEntry = pageDict["Annots"] else {
            return []
        }
        return resolve(annotsEntry)?.arrayValue ?? []
    }

    /// Replaces the `/Annots` array for `page`, preserving indirect `/Annots N G R` arrays
    /// when present and updating the page dictionary when `/Annots` is direct or absent.
    func setPageAnnots(_ annots: [PDFObject], for page: PDFPageRecord) {
        var pageDict = currentObject(number: page.pageObjNum, generation: page.pageGenNum)?.dictValue
            ?? page.pageDict

        if case let .indirectRef(annotsObjNum, annotsGenNum) = pageDict["Annots"] {
            if annots.isEmpty {
                setObject(.array([]), number: annotsObjNum, generation: annotsGenNum)
                pageDict.removeValue(forKey: "Annots")
                setObject(.dict(pageDict), number: page.pageObjNum, generation: page.pageGenNum)
            } else {
                setObject(.array(annots), number: annotsObjNum, generation: annotsGenNum)
            }
        } else {
            if annots.isEmpty {
                pageDict.removeValue(forKey: "Annots")
            } else {
                pageDict["Annots"] = .array(annots)
            }
            setObject(.dict(pageDict), number: page.pageObjNum, generation: page.pageGenNum)
        }
    }

    /// Appends an annotation indirect reference to `page`'s `/Annots` array.
    func appendAnnot(_ ref: PDFIndirectRef, to page: PDFPageRecord) {
        var annots = pageAnnots(for: page)
        annots.append(.indirectRef(objNum: ref.objNum, genNum: ref.genNum))
        setPageAnnots(annots, for: page)
    }

    /// Removes the annotation with object number `objNum` from `page`'s `/Annots` array.
    @discardableResult
    func removeAnnot(objNum: Int, from page: PDFPageRecord) -> Bool {
        var annots = pageAnnots(for: page)
        let originalCount = annots.count
        annots.removeAll { item in
            if case let .indirectRef(num, _) = item {
                return num == objNum
            }
            return false
        }
        guard annots.count != originalCount else { return false }
        setPageAnnots(annots, for: page)
        return true
    }

    // MARK: - Build Incremental PDF

    /// Produces only the incremental update bytes to append after `store.rawData`,
    /// or empty `Data` when no objects were modified.
    func buildIncrementalSuffix() -> Data {
        guard !updatedObjects.isEmpty else {
            return Data()
        }

        let baseCount = store.rawData.count
        var suffix = Data()
        if let lastByte = store.rawData.last, lastByte != 0x0A && lastByte != 0x0D {
            suffix.append(0x0A)
        }

        let headerOffset = store.pdfHeaderOffset
        let sortedObjNums = updatedObjects.keys.sorted()
        var writtenOffsets: [(objNum: Int, genNum: Int, offset: Int)] = []
        writtenOffsets.reserveCapacity(sortedObjNums.count + 1)

        for objNum in sortedObjNums {
            guard let entry = updatedObjects[objNum] else { continue }
            let offset = (baseCount + suffix.count) - headerOffset
            writtenOffsets.append((objNum: objNum, genNum: entry.genNum, offset: offset))

            let preparedObject = prepareForSerialization(
                entry.object,
                objNum: objNum,
                genNum: entry.genNum
            )
            let serialized = PDFSerializer.serializeIndirectObject(
                objNum: objNum,
                genNum: entry.genNum,
                object: preparedObject
            )
            suffix.append(serialized)
            if suffix.last != 0x0A {
                suffix.append(0x0A)
            }
        }

        if store.usesXRefStreams {
            appendXRefStream(to: &suffix, baseCount: baseCount, entries: writtenOffsets, headerOffset: headerOffset)
        } else {
            appendClassicXRef(to: &suffix, baseCount: baseCount, entries: writtenOffsets, headerOffset: headerOffset)
        }

        return suffix
    }

    /// Produces the complete PDF bytes consisting of the original PDF followed by the
    /// appended incremental update section.
    func buildData() -> Data {
        let suffix = buildIncrementalSuffix()
        guard !suffix.isEmpty else {
            return store.rawData
        }
        var output = Data(capacity: store.rawData.count + suffix.count)
        output.append(store.rawData)
        output.append(suffix)
        return output
    }

    /// Appends the incremental update onto a copy-on-write clone of `destinationURL`
    /// when the on-disk size matches `store.rawData`, falling back to full atomic write otherwise.
    /// Returns the appended incremental suffix bytes (empty if there are no pending changes).
    @discardableResult
    func saveIncrementally(to destinationURL: URL) throws -> Data {
        let suffix = buildIncrementalSuffix()
        guard !suffix.isEmpty else { return Data() }

        let fileManager = FileManager.default
        let target = destinationURL.resolvingSymlinksInPath()
        var st = Darwin.stat()
        if stat(target.path, &st) == 0,
           Int64(st.st_size) == Int64(store.rawData.count),
           let tempDir = try? Self.makeReplacementDirectory(for: target, fileManager: fileManager) {
            defer { try? fileManager.removeItem(at: tempDir) }
            let tempFileURL = tempDir.appendingPathComponent("output.pdf")
            do {
                try fileManager.copyItem(at: target, to: tempFileURL)
                let handle = try FileHandle(forUpdating: tempFileURL)
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: suffix)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                let expectedSize = Int64(store.rawData.count + suffix.count)
                let writtenSize = (try? fileManager.attributesOfItem(atPath: tempFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                if writtenSize == expectedSize {
                    _ = try fileManager.replaceItemAt(target, withItemAt: tempFileURL)
                    return suffix
                }
            } catch {
                // Fall through to full atomic write below.
            }
        }

        try Self.saveAtomically(buildData(), to: destinationURL)
        return suffix
    }

    /// Writes `data` atomically to `destinationURL` via a same-volume item replacement
    /// directory (falling back to the system temporary directory) and `FileManager.replaceItemAt`.
    static func saveAtomically(_ data: Data, to destinationURL: URL) throws {
        guard !data.isEmpty else {
            throw WriterError.emptyOutput
        }
        let fileManager = FileManager.default
        let target = destinationURL.resolvingSymlinksInPath()
        let tempDir = try makeReplacementDirectory(for: target, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: tempDir) }

        let tempFileURL = tempDir.appendingPathComponent("output.pdf")
        try data.write(to: tempFileURL)

        let writtenSize = (try? fileManager.attributesOfItem(atPath: tempFileURL.path)[.size] as? Int) ?? 0
        guard writtenSize > 0 else {
            throw WriterError.emptyOutput
        }

        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: tempFileURL)
        } catch {
            try data.write(to: target, options: .atomic)
        }
    }

    private static func makeReplacementDirectory(for target: URL, fileManager: FileManager) throws -> URL {
        if let replacementDir = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        ) {
            return replacementDir
        }
        let fallbackDir = fileManager.temporaryDirectory
            .appendingPathComponent("AnnotView-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir
    }

    // MARK: - Encryption & Stream Length Preparation

    private func prepareForSerialization(
        _ object: PDFObject,
        objNum: Int,
        genNum: Int
    ) -> PDFObject {
        if let handler = store.securityHandler {
            return encryptObject(object, objNum: objNum, genNum: genNum, handler: handler)
        }
        if case let .stream(dict, data) = object {
            var updatedDict = dict
            updatedDict["Length"] = .int(Int64(data.count))
            return .stream(dict: updatedDict, data: data)
        }
        return object
    }

    private func encryptObject(
        _ object: PDFObject,
        objNum: Int,
        genNum: Int,
        handler: PDFSecurityHandler
    ) -> PDFObject {
        switch object {
        case .string(let data):
            return .string(handler.encryptString(data, objNum: objNum, genNum: genNum))
        case .array(let items):
            return .array(items.map { encryptObject($0, objNum: objNum, genNum: genNum, handler: handler) })
        case .dict(let dict):
            var result: [String: PDFObject] = Dictionary(minimumCapacity: dict.count)
            for (key, value) in dict {
                result[key] = encryptObject(value, objNum: objNum, genNum: genNum, handler: handler)
            }
            return .dict(result)
        case .stream(let dict, let data):
            var encryptedDict: [String: PDFObject] = Dictionary(minimumCapacity: dict.count + 1)
            for (key, value) in dict {
                encryptedDict[key] = encryptObject(value, objNum: objNum, genNum: genNum, handler: handler)
            }
            let encryptedData = handler.encryptStream(data, objNum: objNum, genNum: genNum)
            encryptedDict["Length"] = .int(Int64(encryptedData.count))
            return .stream(dict: encryptedDict, data: encryptedData)
        case .null, .bool, .int, .real, .name, .indirectRef:
            return object
        }
    }

    // MARK: - Classic XRef Table

    private func appendClassicXRef(
        to output: inout Data,
        baseCount: Int,
        entries: [(objNum: Int, genNum: Int, offset: Int)],
        headerOffset: Int
    ) {
        let xrefOffset = (baseCount + output.count) - headerOffset
        let subsections = groupIntoSubsections(entries)

        var xrefText = "xref\n"
        for subsection in subsections {
            guard let first = subsection.first else { continue }
            xrefText += "\(first.objNum) \(subsection.count)\n"
            for entry in subsection {
                let offsetStr = zeroPadded(entry.offset, width: 10)
                let genStr = zeroPadded(entry.genNum, width: 5)
                xrefText += "\(offsetStr) \(genStr) n \n"
            }
        }
        output.append(Data(xrefText.utf8))

        let oldSize = store.trailer["Size"]?.intValue ?? 0
        let maxWritten = entries.map(\.objNum).max() ?? 0
        let newSize = max(oldSize, max(nextObjNum, maxWritten + 1))

        var trailerDict: [String: PDFObject] = [:]
        for key in ["Root", "Info", "ID", "Encrypt"] {
            if let value = store.trailer[key] {
                trailerDict[key] = value
            }
        }
        trailerDict["Size"] = .int(Int64(newSize))
        if store.lastStartXRef > 0 {
            trailerDict["Prev"] = .int(Int64(store.lastStartXRef))
        }

        output.append(Data("trailer\n".utf8))
        output.append(PDFSerializer.serialize(.dict(trailerDict)))
        output.append(Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    }

    // MARK: - PDF 1.5+ Cross-Reference Stream

    private func appendXRefStream(
        to output: inout Data,
        baseCount: Int,
        entries: [(objNum: Int, genNum: Int, offset: Int)],
        headerOffset: Int
    ) {
        let xrefObjNum = nextObjNum
        let nextAfterXRef = nextObjNum + 1
        let xrefOffset = (baseCount + output.count) - headerOffset

        var allEntries = entries
        allEntries.append((objNum: xrefObjNum, genNum: 0, offset: xrefOffset))
        allEntries.sort { $0.objNum < $1.objNum }

        let subsections = groupIntoSubsections(allEntries)
        let maxOffset = allEntries.map(\.offset).max() ?? 0
        let offsetWidth = maxOffset > 0xFFFF_FFFF ? 8 : 4

        var indexArray: [PDFObject] = []
        var streamData = Data()
        streamData.reserveCapacity(allEntries.count * (1 + offsetWidth + 2))

        for subsection in subsections {
            guard let first = subsection.first else { continue }
            indexArray.append(.int(Int64(first.objNum)))
            indexArray.append(.int(Int64(subsection.count)))
            for entry in subsection {
                // Type 1: uncompressed indirect object
                streamData.append(1)
                appendBigEndian(UInt64(entry.offset), width: offsetWidth, to: &streamData)
                appendBigEndian(UInt64(entry.genNum), width: 2, to: &streamData)
            }
        }

        let oldSize = store.trailer["Size"]?.intValue ?? 0
        let newSize = max(oldSize, max(nextAfterXRef, xrefObjNum + 1))

        var xrefDict: [String: PDFObject] = [
            "Type": .name("XRef"),
            "Size": .int(Int64(newSize)),
            "W": .array([.int(1), .int(Int64(offsetWidth)), .int(2)]),
            "Index": .array(indexArray),
            "Length": .int(Int64(streamData.count)),
        ]
        if store.lastStartXRef > 0 {
            xrefDict["Prev"] = .int(Int64(store.lastStartXRef))
        }
        for key in ["Root", "Info", "ID", "Encrypt"] {
            if let value = store.trailer[key] {
                xrefDict[key] = value
            }
        }

        // Cross-reference streams must NOT be encrypted (ISO 32000-1 §7.6.1).
        let xrefStream = PDFObject.stream(dict: xrefDict, data: streamData)
        output.append(
            PDFSerializer.serializeIndirectObject(
                objNum: xrefObjNum,
                genNum: 0,
                object: xrefStream
            )
        )
        if output.last != 0x0A {
            output.append(0x0A)
        }
        output.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
    }

    // MARK: - Formatting Helpers

    private func groupIntoSubsections(
        _ entries: [(objNum: Int, genNum: Int, offset: Int)]
    ) -> [[(objNum: Int, genNum: Int, offset: Int)]] {
        var result: [[(objNum: Int, genNum: Int, offset: Int)]] = []
        for entry in entries {
            if let lastGroup = result.last,
               let lastEntry = lastGroup.last,
               entry.objNum == lastEntry.objNum + 1 {
                result[result.count - 1].append(entry)
            } else {
                result.append([entry])
            }
        }
        return result
    }

    private func zeroPadded(_ value: Int, width: Int) -> String {
        let str = String(value)
        if str.count >= width { return str }
        return String(repeating: "0", count: width - str.count) + str
    }

    private func appendBigEndian(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }
}
