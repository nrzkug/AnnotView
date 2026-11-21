import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import AnnotView

struct SwiftPDFCoreTests {

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor
    private func writeBlankPDF(
        to url: URL,
        size: NSSize = NSSize(width: 612, height: 792),
        rotation: Int = 0,
        cropBox: CGRect? = nil
    ) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))
        page.rotation = rotation
        if let cropBox {
            page.setBounds(cropBox, for: .cropBox)
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        #expect(document.write(to: url))
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. Sample PDF Parsing & PDFKit Cross-Reader Verification

    @Test
    func parsesRepoSamplePDFsCleanly() async throws {
        let relativePaths = [
            "docs/samples/annotview-review-demo.pdf",
            "output/pdf/annotview-review-sample.pdf"
        ]
        let swiftParser = SwiftPDFAnnotationParser()

        var testedCount = 0
        for rel in relativePaths {
            let url = Self.repoRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            testedCount += 1

            let swiftAnnots = try await swiftParser.annotations(in: url)
            #expect(!swiftAnnots.isEmpty, "\(rel) should contain annotations")
            #expect(swiftAnnots.allSatisfy { $0.sourceID != nil })
            #expect(swiftAnnots.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 })

            // Cross-verify page count against PDFKit
            let pdfKitDoc = try #require(PDFDocument(url: url))
            let store = try PDFDocumentStore(url: url)
            #expect(store.pages().count == pdfKitDoc.pageCount)
        }
        #expect(testedCount >= 1)
    }

    // MARK: - 2. COS Unit Tests (Lexer, TextString, Date, Filters, XRef/ObjStm/Repair)

    @Test
    func lexerHandlesEdgeCases() throws {
        // Comments, nested parens, octal escapes, line continuation, hex strings (odd & even), #XX names, indirect refs
        let raw = """
        % comment line 1
        << /Name#20With#23Hash (Hello (nested (parens)) \\101\\012line\\\ncont)
           /HexEven <48656C6C6F>
           /HexOdd <414>
           /Arr [1 -2 3.5 true false null 12 0 R]
        >>
        """
        var lexer = PDFLexer(data: Data(raw.utf8))
        let parsed = lexer.parseObject()
        let obj = try #require(parsed)
        let dict = try #require(obj.dictValue)

        let strVal = try #require(dict["Name With#Hash"]?.stringData)
        #expect(String(decoding: strVal, as: UTF8.self) == "Hello (nested (parens)) A\nlinecont")

        let hexEven = try #require(dict["HexEven"]?.stringData)
        #expect(String(decoding: hexEven, as: UTF8.self) == "Hello")

        // Odd hex <414> -> padded with trailing 0 -> 0x41, 0x40 ("A@")
        let hexOdd = try #require(dict["HexOdd"]?.stringData)
        #expect(Array(hexOdd) == [0x41, 0x40])

        let arr = try #require(dict["Arr"]?.arrayValue)
        #expect(arr.count == 7)
        #expect(arr[0] == .int(1))
        #expect(arr[1] == .int(-2))
        #expect(arr[2] == .real(3.5))
        #expect(arr[3] == .bool(true))
        #expect(arr[4] == .bool(false))
        #expect(arr[5] == .null)
        #expect(arr[6] == .indirectRef(objNum: 12, genNum: 0))
    }

    @Test
    func textStringDecodesAndEncodesAllEncodings() {
        // UTF-16BE with BOM
        let utf16BE = Data([0xFE, 0xFF, 0x4E, 0x2D, 0x65, 0x87]) // "中文"
        #expect(PDFTextString.decode(utf16BE) == "中文")

        // UTF-8 with BOM
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data("Hello 中文".utf8)
        #expect(PDFTextString.decode(utf8BOM) == "Hello 中文")

        // PDFDocEncoding special codepoints (Table D.2):
        // 0x84 = em-dash (—), 0x8D = left double quote (“), 0x8E = right double quote (”), 0xA0 = Euro (€)
        let pdfDoc = Data([0x41, 0x84, 0x8D, 0x42, 0x8E, 0xA0])
        #expect(PDFTextString.decode(pdfDoc) == "A\u{2014}\u{201C}B\u{201D}\u{20AC}")

        // Encode/decode round-trips
        let samples = [
            "Simple ASCII text",
            #"Define "alpha" and (parens) and \slash"#,
            "中文批注测试「引号」",
            "Café — “quoted” €100",
            "Emoji 🚀 test"
        ]
        for s in samples {
            let encoded = PDFTextString.encode(s)
            #expect(PDFTextString.decode(encoded) == s)
        }
        // CJK must use UTF-16BE BOM so Acrobat & Preview decode it reliably
        let cjkEncoded = PDFTextString.encode("中文")
        #expect(cjkEncoded.starts(with: [0xFE, 0xFF]))
    }

    @Test
    func pdfDateParsesAndFormats() throws {
        let d1 = try #require(PDFDate.parse("D:20260809152000Z"))
        let iso = ISO8601DateFormatter()
        #expect(d1 == iso.date(from: "2026-08-09T15:20:00Z"))

        // Timezone offset +08'00'
        let d2 = try #require(PDFDate.parse("D:20260809232000+08'00'"))
        #expect(d2 == d1)

        // Negative timezone offset -05'30'
        let d3 = try #require(PDFDate.parse("D:20260809095000-05'30'"))
        #expect(d3 == d1)

        // Partial variants
        #expect(PDFDate.parse("D:2026") != nil)
        #expect(PDFDate.parse("D:20260809") != nil)
        #expect(PDFDate.parse("D:202608091520") != nil)

        // Format round-trip
        let formatted = PDFDate.format(d1)
        #expect(formatted == "D:20260809152000Z")
        #expect(PDFDate.parse(formatted) == d1)
    }

    @Test
    func streamFiltersDecodeFlateASCIIAndPredictors() throws {
        // 1. FlateDecode round-trip
        let payload = Data(repeating: 0x41, count: 100) + Data("Hello PDF FlateDecode!".utf8)
        let compressed = try PDFStreamFilter.flateEncode(payload)
        let decompressed = try PDFStreamFilter.decode(compressed, filter: .name("FlateDecode"), decodeParms: nil)
        #expect(decompressed == payload)

        // 2. ASCIIHexDecode
        let hexDecoded = try PDFStreamFilter.decode(
            Data("48 65 6C 6C 6F>".utf8),
            filter: .name("ASCIIHexDecode"),
            decodeParms: nil
        )
        #expect(String(decoding: hexDecoded, as: UTF8.self) == "Hello")

        // 3. ASCII85Decode ("87cURD]j7BEbo80~>" -> "Hello world!")
        let a85Decoded = try PDFStreamFilter.decode(
            Data("87cURD]j7BEbo80~>".utf8),
            filter: .name("ASCII85Decode"),
            decodeParms: nil
        )
        #expect(String(decoding: a85Decoded, as: UTF8.self) == "Hello world!")

        // 4. PNG Predictors (10-15): None(0), Sub(1), Up(2), Average(3), Paeth(4)
        // Row width = 4 bytes, 1 component, 8 bpc
        // Expected decoded rows:
        // Row 0: [10, 20, 30, 40] (None: 0, 10, 20, 30, 40)
        // Row 1: [12, 22, 32, 42] (Sub:  1, 12, 10, 10, 10)
        // Row 2: [15, 25, 35, 45] (Up:   2,  3,  3,  3,  3)
        let pngPredicted = Data([
            0, 10, 20, 30, 40,
            1, 12, 10, 10, 10,
            2, 3, 3, 3, 3
        ])
        let pngCompressed = try PDFStreamFilter.flateEncode(pngPredicted)
        let pngDecoded = try PDFStreamFilter.decode(
            pngCompressed,
            filter: .name("FlateDecode"),
            decodeParms: .dict([
                "Predictor": .int(12),
                "Columns": .int(4),
                "Colors": .int(1),
                "BitsPerComponent": .int(8)
            ])
        )
        #expect(Array(pngDecoded) == [
            10, 20, 30, 40,
            12, 22, 32, 42,
            15, 25, 35, 45
        ])

        // 5. TIFF Predictor 2 (horizontal differencing, 8 bpc, 1 color, 4 columns)
        // Input diffs [10, 10, 10, 10] -> [10, 20, 30, 40]
        let tiffPredicted = Data([10, 10, 10, 10, 5, 5, 5, 5])
        let tiffCompressed = try PDFStreamFilter.flateEncode(tiffPredicted)
        let tiffDecoded = try PDFStreamFilter.decode(
            tiffCompressed,
            filter: .name("FlateDecode"),
            decodeParms: .dict([
                "Predictor": .int(2),
                "Columns": .int(4),
                "Colors": .int(1),
                "BitsPerComponent": .int(8)
            ])
        )
        #expect(Array(tiffDecoded) == [10, 20, 30, 40, 5, 10, 15, 20])
    }

    @Test
    func documentStoreReadsXRefStreamAndObjStmAndRepairsCorruptXRef() throws {
        // Construct a minimal PDF 1.5 with an /ObjStm (obj 3 containing obj 1 & obj 2)
        // and a /Type /XRef stream (obj 4)
        var pdf = Data("%PDF-1.5\n".utf8)

        // Object 3: /ObjStm containing:
        //   obj 1: << /Type /Catalog /Pages 2 0 R >>
        //   obj 2: << /Type /Pages /Kids [5 0 R] /Count 1 /MediaBox [0 0 612 792] >>
        let obj1Str = "<< /Type /Catalog /Pages 2 0 R >>"
        let obj2Str = "<< /Type /Pages /Kids [5 0 R] /Count 1 /MediaBox [0 0 612 792] >>"
        let headerStr = "1 0 2 \(obj1Str.utf8.count + 1) "
        let objStmPlain = Data((headerStr + obj1Str + " " + obj2Str).utf8)
        let objStmCompressed = try PDFStreamFilter.flateEncode(objStmPlain)

        let obj3Offset = pdf.count
        pdf.append(Data("3 0 obj\n<< /Type /ObjStm /N 2 /First \(headerStr.utf8.count) /Filter /FlateDecode /Length \(objStmCompressed.count) >>\nstream\n".utf8))
        pdf.append(objStmCompressed)
        pdf.append(Data("\nendstream\nendobj\n".utf8))

        // Object 5: uncompressed Page object
        let obj5Offset = pdf.count
        pdf.append(Data("5 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n".utf8))

        // Object 4: /Type /XRef stream with /W [1 2 1] for objects 0..5
        let xrefOffset = pdf.count
        func xrefRow(_ t: UInt8, _ f2: Int, _ f3: UInt8) -> [UInt8] {
            [t, UInt8((f2 >> 8) & 0xFF), UInt8(f2 & 0xFF), f3]
        }
        var xrefRaw = Data()
        xrefRaw.append(contentsOf: xrefRow(0, 0, 255))       // obj 0: free
        xrefRaw.append(contentsOf: xrefRow(2, 3, 0))         // obj 1: in ObjStm 3, index 0
        xrefRaw.append(contentsOf: xrefRow(2, 3, 1))         // obj 2: in ObjStm 3, index 1
        xrefRaw.append(contentsOf: xrefRow(1, obj3Offset, 0)) // obj 3
        xrefRaw.append(contentsOf: xrefRow(1, xrefOffset, 0)) // obj 4
        xrefRaw.append(contentsOf: xrefRow(1, obj5Offset, 0)) // obj 5
        let xrefCompressed = try PDFStreamFilter.flateEncode(xrefRaw)

        pdf.append(Data("4 0 obj\n<< /Type /XRef /Size 6 /Root 1 0 R /W [1 2 1] /Filter /FlateDecode /Length \(xrefCompressed.count) >>\nstream\n".utf8))
        pdf.append(xrefCompressed)
        pdf.append(Data("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))

        let store = try PDFDocumentStore(data: pdf)
        #expect(store.usesXRefStreams)
        let pages = store.pages()
        #expect(pages.count == 1)
        #expect(pages[0].pageObjNum == 5)
        #expect(pages[0].mediaBox == CGRect(x: 0, y: 0, width: 612, height: 792))

        // Now test xref repair fallback with a corrupted startxref on a classic PDF
        let corruptPDF = Data("""
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] >>
        endobj
        trailer
        << /Size 4 /Root 1 0 R >>
        startxref
        999999
        %%EOF
        """.utf8)
        let repairedStore = try PDFDocumentStore(data: corruptPDF)
        let repairedPages = repairedStore.pages()
        #expect(repairedPages.count == 1)
        #expect(repairedPages[0].mediaBox == CGRect(x: 0, y: 0, width: 400, height: 500))
    }

    // MARK: - 3. Encryption Tests (RC4-40, RC4-128, AES-128, AES-256, End-to-End)

    private func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private func rc4(_ key: Data, _ input: Data) -> Data {
        var s = Array(0..<256)
        var j = 0
        let k = Array(key)
        for i in 0..<256 {
            j = (j + s[i] + Int(k[i % k.count])) & 0xFF
            s.swapAt(i, j)
        }
        var out = Data(count: input.count)
        var i = 0
        j = 0
        for idx in 0..<input.count {
            i = (i + 1) & 0xFF
            j = (j + s[i]) & 0xFF
            s.swapAt(i, j)
            let t = (s[i] + s[j]) & 0xFF
            out[idx] = input[idx] ^ UInt8(s[t])
        }
        return out
    }

    private func buildLegacyEncryptDict(
        version: Int,
        revision: Int,
        keyLengthBits: Int,
        fileID: Data,
        userPassword: String = "",
        ownerPassword: String = "owner",
        useAES128: Bool = false
    ) -> [String: PDFObject] {
        let pad = PDFSecurityHandler.standardPadding
        func padPwd(_ s: String) -> Data {
            var d = Data(s.utf8.prefix(32))
            if d.count < 32 { d.append(contentsOf: pad.prefix(32 - d.count)) }
            return d
        }
        let keyLen = keyLengthBits / 8
        let pVal: Int32 = -4 // all permissions except bits 1-2

        // Algorithm 3: Compute /O
        var oHash = md5(padPwd(ownerPassword))
        if revision >= 3 {
            for _ in 0..<50 { oHash = md5(oHash) }
        }
        let oKey = Data(oHash.prefix(keyLen))
        var oValue = rc4(oKey, padPwd(userPassword))
        if revision >= 3 {
            for i in 1...19 {
                let iterKey = Data(oKey.map { $0 ^ UInt8(i) })
                oValue = rc4(iterKey, oValue)
            }
        }

        // Algorithm 2: Compute file encryption key
        var keyInput = Data()
        keyInput.append(padPwd(userPassword))
        keyInput.append(oValue)
        var pLE = UInt32(bitPattern: pVal).littleEndian
        keyInput.append(Data(bytes: &pLE, count: 4))
        keyInput.append(fileID)
        var hash = md5(keyInput)
        if revision >= 3 {
            for _ in 0..<50 {
                hash = md5(Data(hash.prefix(keyLen)))
            }
        }
        let fileKey = Data(hash.prefix(keyLen))

        // Algorithm 4 / 5: Compute /U
        let uValue: Data
        if revision == 2 {
            uValue = rc4(fileKey, Data(pad))
        } else {
            var uInput = Data(pad)
            uInput.append(fileID)
            var uHash = rc4(fileKey, md5(uInput))
            for i in 1...19 {
                let iterKey = Data(fileKey.map { $0 ^ UInt8(i) })
                uHash = rc4(iterKey, uHash)
            }
            uHash.append(Data(repeating: 0, count: 16))
            uValue = uHash
        }

        var dict: [String: PDFObject] = [
            "Filter": .name("Standard"),
            "V": .int(Int64(version)),
            "R": .int(Int64(revision)),
            "Length": .int(Int64(keyLengthBits)),
            "P": .int(Int64(pVal)),
            "O": .string(oValue),
            "U": .string(uValue)
        ]
        if version == 4 && useAES128 {
            dict["CF"] = .dict([
                "StdCF": .dict([
                    "CFM": .name("AESV2"),
                    "AuthEvent": .name("DocOpen"),
                    "Length": .int(16)
                ])
            ])
            dict["StmF"] = .name("StdCF")
            dict["StrF"] = .name("StdCF")
        }
        return dict
    }

    private func buildAES256R5EncryptDict(userPassword: String = "") throws -> [String: PDFObject] {
        // R=5 (SHA-256) empty-password encryption dictionary
        let pwd = Data(userPassword.utf8)
        let uValSalt = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let uKeySalt = Data([9, 10, 11, 12, 13, 14, 15, 16])
        let oValSalt = Data([17, 18, 19, 20, 21, 22, 23, 24])
        let oKeySalt = Data([25, 26, 27, 28, 29, 30, 31, 32])

        let uHash = Data(SHA256.hash(data: pwd + uValSalt))
        let uEntry = uHash + uValSalt + uKeySalt

        let oHash = Data(SHA256.hash(data: pwd + oValSalt + uEntry))
        let oEntry = oHash + oValSalt + oKeySalt

        let fileKey = Data((0..<32).map { UInt8($0 + 0x10) })

        func aes256CBCNoPadEncrypt(key: Data, plaintext: Data) throws -> Data {
            var out = Data(count: plaintext.count + kCCBlockSizeAES128)
            var numBytes = 0
            let zeroIV = Data(repeating: 0, count: 16)
            let status = out.withUnsafeMutableBytes { outPtr in
                plaintext.withUnsafeBytes { inPtr in
                    key.withUnsafeBytes { keyPtr in
                        zeroIV.withUnsafeBytes { ivPtr in
                            CCCrypt(
                                CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                0, // no padding
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                inPtr.baseAddress, plaintext.count,
                                outPtr.baseAddress, outPtr.count,
                                &numBytes
                            )
                        }
                    }
                }
            }
            #expect(status == kCCSuccess)
            return out.prefix(numBytes)
        }

        let ueKey = Data(SHA256.hash(data: pwd + uKeySalt))
        let ueEntry = try aes256CBCNoPadEncrypt(key: ueKey, plaintext: fileKey)

        let oeKey = Data(SHA256.hash(data: pwd + oKeySalt + uEntry))
        let oeEntry = try aes256CBCNoPadEncrypt(key: oeKey, plaintext: fileKey)

        return [
            "Filter": .name("Standard"),
            "V": .int(5),
            "R": .int(5),
            "Length": .int(256),
            "P": .int(-4),
            "U": .string(uEntry),
            "O": .string(oEntry),
            "UE": .string(ueEntry),
            "OE": .string(oeEntry),
            "CF": .dict([
                "StdCF": .dict([
                    "CFM": .name("AESV3"),
                    "AuthEvent": .name("DocOpen"),
                    "Length": .int(32)
                ])
            ]),
            "StmF": .name("StdCF"),
            "StrF": .name("StdCF")
        ]
    }

    @Test
    func securityHandlerRoundTripsRC4AES128AndAES256() throws {
        let fileID = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
                           0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10])
        let plaintext = Data("Confidential PDF annotation content 中文!".utf8)

        // 1. RC4-40 (V=1, R=2)
        let rc40Dict = buildLegacyEncryptDict(version: 1, revision: 2, keyLengthBits: 40, fileID: fileID)
        let rc40 = try PDFSecurityHandler(encryptDict: rc40Dict, fileID: fileID, password: "")
        let rc40Enc = rc40.encryptString(plaintext, objNum: 7, genNum: 0)
        #expect(rc40Enc != plaintext)
        #expect(rc40.decryptString(rc40Enc, objNum: 7, genNum: 0) == plaintext)

        // 2. RC4-128 (V=2, R=3)
        let rc128Dict = buildLegacyEncryptDict(version: 2, revision: 3, keyLengthBits: 128, fileID: fileID)
        let rc128 = try PDFSecurityHandler(encryptDict: rc128Dict, fileID: fileID, password: "")
        let rc128Enc = rc128.encryptStream(plaintext, objNum: 10, genNum: 0)
        #expect(rc128Enc != plaintext)
        #expect(rc128.decryptStream(rc128Enc, objNum: 10, genNum: 0) == plaintext)

        // 3. AES-128 (V=4, R=4, AESV2)
        let aes128Dict = buildLegacyEncryptDict(version: 4, revision: 4, keyLengthBits: 128, fileID: fileID, useAES128: true)
        let aes128 = try PDFSecurityHandler(encryptDict: aes128Dict, fileID: fileID, password: "")
        let aes128Enc = aes128.encryptString(plaintext, objNum: 15, genNum: 0)
        #expect(aes128Enc.count >= plaintext.count + 16) // 16-byte IV + PKCS7
        #expect(aes128.decryptString(aes128Enc, objNum: 15, genNum: 0) == plaintext)

        // 4. AES-256 (V=5, R=5, AESV3)
        let aes256Dict = try buildAES256R5EncryptDict(userPassword: "")
        let aes256 = try PDFSecurityHandler(encryptDict: aes256Dict, fileID: fileID, password: "")
        let aes256Enc = aes256.encryptStream(plaintext, objNum: 20, genNum: 0)
        #expect(aes256Enc.count >= plaintext.count + 16)
        #expect(aes256.decryptStream(aes256Enc, objNum: 20, genNum: 0) == plaintext)

        // 5. Password-protected PDF rejects empty password with .passwordRequired
        let lockedDict = buildLegacyEncryptDict(
            version: 4, revision: 4, keyLengthBits: 128, fileID: fileID,
            userPassword: "secret", useAES128: true
        )
        #expect(throws: PDFSecurityError.passwordRequired) {
            _ = try PDFSecurityHandler(encryptDict: lockedDict, fileID: fileID, password: "")
        }
        let unlocked = try PDFSecurityHandler(encryptDict: lockedDict, fileID: fileID, password: "secret")
        let enc = unlocked.encryptString(plaintext, objNum: 3, genNum: 0)
        #expect(unlocked.decryptString(enc, objNum: 3, genNum: 0) == plaintext)
    }

    @Test
    func encryptedPDFEndToEndReadAndIncrementalWrite() async throws {
        let dir = try makeTempDir("SwiftPDFEncrypted")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("encrypted.pdf")

        let fileID = Data([0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44,
                           0x55, 0x66, 0x77, 0x88, 0x99, 0x00, 0xAB, 0xCD])
        let encryptDict = buildLegacyEncryptDict(
            version: 4, revision: 4, keyLengthBits: 128, fileID: fileID,
            userPassword: "", useAES128: true
        )

        // Build a minimal encrypted PDF on disk
        var pdf = Data("%PDF-1.6\n".utf8)
        var offsets: [Int: Int] = [:]
        func appendObj(_ num: Int, _ obj: PDFObject) {
            offsets[num] = pdf.count
            pdf.append(PDFSerializer.serializeIndirectObject(objNum: num, genNum: 0, object: obj))
        }
        appendObj(1, .dict(["Type": .name("Catalog"), "Pages": .indirectRef(objNum: 2, genNum: 0)]))
        appendObj(2, .dict([
            "Type": .name("Pages"),
            "Kids": .array([.indirectRef(objNum: 3, genNum: 0)]),
            "Count": .int(1)
        ]))
        appendObj(3, .dict([
            "Type": .name("Page"),
            "Parent": .indirectRef(objNum: 2, genNum: 0),
            "MediaBox": .array([.int(0), .int(0), .int(612), .int(792)])
        ]))
        appendObj(4, .dict(encryptDict))

        let xrefOffset = pdf.count
        pdf.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for i in 1...4 {
            pdf.append(Data(String(format: "%010d 00000 n \n", offsets[i]!).utf8))
        }
        let trailer = PDFObject.dict([
            "Size": .int(5),
            "Root": .indirectRef(objNum: 1, genNum: 0),
            "Encrypt": .indirectRef(objNum: 4, genNum: 0),
            "ID": .array([.string(fileID), .string(fileID)])
        ])
        pdf.append(Data("trailer\n".utf8))
        pdf.append(PDFSerializer.serialize(trailer))
        pdf.append(Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try pdf.write(to: url)

        // Write a note into the encrypted PDF using SwiftPDFAnnotationWriter
        let writer = SwiftPDFAnnotationWriter()
        try await writer.createNote(
            in: url,
            location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 200, y: 400)),
            contents: "Encrypted note 中文",
            author: "Tester",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        // Verify with BOTH SwiftPDFAnnotationParser AND PDFKit!
        let swiftAnnots = try await SwiftPDFAnnotationParser().annotations(in: url)
        #expect(swiftAnnots.count == 1)
        #expect(swiftAnnots[0].contents == "Encrypted note 中文")
        #expect(swiftAnnots[0].author == "Tester")
        let pdfKitDoc = try #require(PDFDocument(url: url))
        #expect(pdfKitDoc.page(at: 0)?.annotations.count == 1)
        #expect(pdfKitDoc.page(at: 0)?.annotations.first?.contents == "Encrypted note 中文")
    }

    // MARK: - 4. Full CRUD, Status, Atomic Rollback, Rotated/Cropped, Caret/StrikeOut, CJK/Quotes

    @Test @MainActor
    func fullCRUDStatusAndCrossReaderVerification() async throws {
        let dir = try makeTempDir("SwiftPDFCRUD")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("crud.pdf")
        try writeBlankPDF(to: url)

        let writer = SwiftPDFAnnotationWriter()
        let parser = SwiftPDFAnnotationParser()
        let statusWriter = SwiftPDFAnnotationStatusWriter()
        let createdAt = try #require(ISO8601DateFormatter().date(from: "2026-08-09T15:20:00Z"))

        let quad = PDFMarkupQuad(
            topLeft: CGPoint(x: 72, y: 700),
            topRight: CGPoint(x: 260, y: 700),
            bottomLeft: CGPoint(x: 72, y: 682),
            bottomRight: CGPoint(x: 260, y: 682)
        )
        let selection = PDFMarkupSelection(
            pages: [PDFMarkupPageSelection(pageIndex: 0, quads: [quad])],
            selectedText: "Selected text"
        )

        // Batch create all 5 annotation kinds with CJK, quotes, parens
        try await writer.perform(
            [
                .createMarkup(
                    kind: .highlight, selection: selection,
                    contents: #"Highlight "alpha" 中文"#, author: "审稿人 (A)",
                    color: .yellow, createdAt: createdAt
                ),
                .createMarkup(
                    kind: .underline, selection: selection,
                    contents: "Underline comment", author: "Reviewer",
                    color: .green, createdAt: createdAt
                ),
                .createMarkup(
                    kind: .strikeout, selection: selection,
                    contents: "Strikeout comment", author: "Reviewer",
                    color: .red, createdAt: createdAt
                ),
                .createNote(
                    location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 320, y: 650)),
                    contents: #"Note "beta" (ok) \path"#, author: "Reviewer",
                    color: .yellow, createdAt: createdAt
                ),
                .createCaret(
                    location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 380, y: 600)),
                    contents: "插入文本 here", author: "Reviewer",
                    color: .red, createdAt: createdAt
                )
            ],
            in: url
        )

        // Update statuses in batch
        let initial = try await parser.annotations(in: url)
        #expect(initial.count == 5)
        let statuses: [Annotation.Status] = [.accepted, .rejected, .cancelled, .completed, .none]
        let statusUpdates = try zip(initial, statuses).map { annot, status in
            AnnotationStatusUpdate(sourceID: try #require(annot.statusTargetSourceID), status: status)
        }
        try await statusWriter.updateStatuses(in: url, updates: statusUpdates)

        // Cross-reader check #1: SwiftPDFAnnotationParser status & fields
        let swiftAnnots = try await parser.annotations(in: url)
        #expect(swiftAnnots.count == 5)
        for (annot, expectedStatus) in zip(swiftAnnots, statuses) {
            #expect(annot.status == expectedStatus)
        }

        // Cross-reader check #2: PDFKit.PDFDocument opens cleanly with all annotations & /AP intact
        let pdfKitDoc = try #require(PDFDocument(url: url))
        let pdfKitPage = try #require(pdfKitDoc.page(at: 0))
        #expect(pdfKitPage.annotations.count == 5)

        // Verify /AP stream exists on every created annotation in PDFDocumentStore
        let store = try PDFDocumentStore(url: url)
        let page = try #require(store.pages().first)
        let annotArray = try #require(store.resolve(page.pageDict["Annots"])?.arrayValue)
        #expect(annotArray.count == 5)
        for entry in annotArray {
            let annotDict = try #require(store.resolve(entry)?.dictValue)
            let apDict = try #require(store.resolve(annotDict["AP"])?.dictValue)
            let nStream = try #require(store.resolve(apDict["N"]))
            let streamData = try store.decodedStreamData(for: nStream)
            #expect(!streamData.isEmpty)
        }

        // Update & Move & Delete round-trip
        let note = try #require(swiftAnnots.first { $0.kind == .note })
        let noteID = try #require(note.sourceID)
        try await writer.update(
            in: url, sourceID: noteID,
            contents: #"Updated "gamma" 中文"#, author: "Editor 2",
            color: .green, modifiedAt: createdAt.addingTimeInterval(120)
        )
        try await writer.move(
            in: url, sourceID: noteID,
            rect: CGRect(x: 450, y: 250, width: 20, height: 20),
            modifiedAt: createdAt.addingTimeInterval(180)
        )

        let afterMove = try await parser.annotations(in: url)
        let movedNote = try #require(afterMove.first { $0.sourceID == noteID })
        #expect(movedNote.contents == #"Updated "gamma" 中文"#)
        #expect(movedNote.author == "Editor 2")
        #expect(abs(movedNote.bounds.minX - 450) < 0.1)
        #expect(abs(movedNote.bounds.minY - 250) < 0.1)

        // Cross-reader check after update+move with PDFKit
        let pdfKitAfterMove = try #require(PDFDocument(url: url))
        #expect(pdfKitAfterMove.page(at: 0)?.annotations.count == 5)

        // Delete note
        try await writer.delete(in: url, sourceID: noteID)
        #expect(try await parser.annotations(in: url).count == 4)
        #expect(try #require(PDFDocument(url: url)).page(at: 0)?.annotations.count == 4)
    }

    @Test @MainActor
    func atomicBatchRollbackLeavesFileUntouched() async throws {
        let dir = try makeTempDir("SwiftPDFRollback")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollback.pdf")
        try writeBlankPDF(to: url)
        let originalBytes = try Data(contentsOf: url)

        let writer = SwiftPDFAnnotationWriter()
        var didThrow = false
        do {
            try await writer.perform(
                [
                    .createNote(
                        location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 100, y: 100)),
                        contents: "Must be rolled back", author: "Reviewer",
                        color: .yellow, createdAt: Date()
                    ),
                    .delete(sourceID: "99999 0 R")
                ],
                in: url
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: url) == originalBytes)
        #expect(try await SwiftPDFAnnotationParser().annotations(in: url).isEmpty)
    }

    @Test @MainActor
    func rotatedCroppedPagesAndUndoRedoWithPureSwiftEngine() async throws {
        let dir = try makeTempDir("SwiftPDFRotatedUndo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rotated.pdf")
        try writeBlankPDF(
            to: url,
            rotation: 270,
            cropBox: CGRect(x: 20, y: 30, width: 572, height: 732)
        )

        let manager = PDFDocumentManager(
            annotationParser: SwiftPDFAnnotationParser(),
            annotationStatusUpdater: SwiftPDFAnnotationStatusWriter(),
            annotationWriter: SwiftPDFAnnotationWriter(),
            displayDocumentPreparer: SwiftPDFDisplayDocumentPreparer()
        )
        await manager.open(url: url)

        // Caret on 270°-rotated cropped page
        let caretPoint = CGPoint(x: 150, y: 420)
        let createdCaret = try #require(
            await manager.createCaret(at: PDFPagePoint(pageIndex: 0, point: caretPoint))
        )
        #expect(abs(createdCaret.bounds.midX - caretPoint.x) < 0.05)
        #expect(abs(createdCaret.bounds.midY - caretPoint.y) < 0.05)

        // Edit with quotes, status change, delete, then multi-step undo & redo
        #expect(await manager.updateAnnotation(createdCaret, contents: #"Define "alpha" here"#))
        #expect(await manager.updateAnnotation(createdCaret, contents: #"Define "beta" 中文"#))
        #expect(await manager.updateStatus(of: createdCaret, to: .completed))
        #expect(manager.annotations.first?.status == .completed)

        let currentCaret = try #require(manager.annotations.first)
        #expect(await manager.deleteAnnotation(currentCaret))
        #expect(manager.annotations.isEmpty)

        // Undo delete restores Caret + status + contents
        await manager.undoAnnotationChange()
        let restored = try #require(manager.annotations.first)
        #expect(restored.kind == .caret)
        #expect(restored.status == .completed)
        #expect(restored.contents == #"Define "beta" 中文"#)

        // Undo second edit steps back to "alpha"
        await manager.undoAnnotationChange()
        #expect(manager.annotations.first?.contents == #"Define "alpha" here"#)

        // Redo restores "beta"
        await manager.redoAnnotationChange()
        #expect(manager.annotations.first?.contents == #"Define "beta" 中文"#)

        // DisplayDocumentPreparer strips annotations cleanly
        let strippedData = try await SwiftPDFDisplayDocumentPreparer().displayData(for: url)
        let strippedDoc = try #require(PDFDocument(data: strippedData))
        #expect(strippedDoc.pageCount == 1)
        #expect(strippedDoc.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test
    func acrobatCaretAndStrikeOutReplacementPairMergesCorrectly() async throws {
        let dir = try makeTempDir("SwiftPDFReplacement")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("replacement.pdf")

        // Build a PDF containing an Acrobat replacement pair:
        // obj 4: Caret (parent) with /Contents, /T, /StateModel /Review, /State /Accepted
        // obj 5: StrikeOut with /IRT 4 0 R and /RT /Group
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]
        func appendObj(_ num: Int, _ obj: PDFObject) {
            offsets[num] = pdf.count
            pdf.append(PDFSerializer.serializeIndirectObject(objNum: num, genNum: 0, object: obj))
        }
        appendObj(1, .dict(["Type": .name("Catalog"), "Pages": .indirectRef(objNum: 2, genNum: 0)]))
        appendObj(2, .dict([
            "Type": .name("Pages"),
            "Kids": .array([.indirectRef(objNum: 3, genNum: 0)]),
            "Count": .int(1)
        ]))
        appendObj(3, .dict([
            "Type": .name("Page"),
            "Parent": .indirectRef(objNum: 2, genNum: 0),
            "MediaBox": .array([.int(0), .int(0), .int(612), .int(792)]),
            "Annots": .array([.indirectRef(objNum: 4, genNum: 0), .indirectRef(objNum: 5, genNum: 0)])
        ]))
        appendObj(4, .dict([
            "Type": .name("Annot"),
            "Subtype": .name("Caret"),
            "Rect": .array([.real(195), .real(682), .real(204), .real(690)]),
            "Contents": .string(PDFTextString.encode("Replacement text")),
            "T": .string(PDFTextString.encode("Acrobat User")),
            "C": .array([.real(0), .real(0), .real(1)]),
            "StateModel": .name("Review"),
            "State": .name("Accepted")
        ]))
        appendObj(5, .dict([
            "Type": .name("Annot"),
            "Subtype": .name("StrikeOut"),
            "Rect": .array([.real(100), .real(682), .real(200), .real(700)]),
            "QuadPoints": .array([
                .real(100), .real(700), .real(200), .real(700),
                .real(100), .real(682), .real(200), .real(682)
            ]),
            "IRT": .indirectRef(objNum: 4, genNum: 0),
            "RT": .name("Group"),
            "C": .array([.real(0), .real(0), .real(1)])
        ]))

        let xrefOffset = pdf.count
        pdf.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
        for i in 1...5 {
            pdf.append(Data(String(format: "%010d 00000 n \n", offsets[i]!).utf8))
        }
        pdf.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        try pdf.write(to: url)

        let swiftAnnots = try await SwiftPDFAnnotationParser().annotations(in: url)
        #expect(swiftAnnots.count == 1)
        #expect(swiftAnnots[0].kind == .strikeout)
        #expect(swiftAnnots[0].contents == "Replacement text")
        #expect(swiftAnnots[0].author == "Acrobat User")
        #expect(swiftAnnots[0].status == .accepted)
        #expect(swiftAnnots[0].statusTargetSourceID == "4 0 R")
        #expect(swiftAnnots[0].bounds == CGRect(x: 100, y: 682, width: 100, height: 18))
    }

    @Test @MainActor
    func displayDocumentPreparerPreservesLinksWhileStrippingOtherAnnotations() async throws {
        let dir = try makeTempDir("SwiftPDFPreserveLinks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("links.pdf")

        let image = NSImage(size: NSSize(width: 400, height: 400))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))

        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 300, width: 80, height: 20), forType: .link, withProperties: nil)
        let highlight = PDFAnnotation(bounds: CGRect(x: 20, y: 200, width: 80, height: 20), forType: .highlight, withProperties: nil)
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
        page.addAnnotation(link)
        page.addAnnotation(highlight)
        page.addAnnotation(note)

        let document = PDFDocument()
        document.insert(page, at: 0)
        #expect(document.write(to: url))

        let strippedData = try await SwiftPDFDisplayDocumentPreparer(storeCache: PDFDocumentStoreCache()).displayData(for: url)
        let strippedDoc = try #require(PDFDocument(data: strippedData))
        let strippedAnnotations = strippedDoc.page(at: 0)?.annotations ?? []
        #expect(strippedAnnotations.count == 1)
        #expect(strippedAnnotations.first?.type == "Link")
    }

    @Test @MainActor
    func documentStoreCacheReusesCachedStoreAndInvalidatesOnExternalModification() async throws {
        let dir = try makeTempDir("SwiftPDFStoreCache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cached.pdf")
        try writeBlankPDF(to: url)

        let cache = PDFDocumentStoreCache()
        let first = try await cache.store(for: url)
        let second = try await cache.store(for: url)
        #expect(first === second)

        // Write via an independent cache/writer to simulate an external file replacement.
        let externalWriter = SwiftPDFAnnotationWriter(storeCache: PDFDocumentStoreCache())
        try await externalWriter.createNote(
            in: url,
            location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 100, y: 200)),
            contents: "External update",
            author: "External",
            color: .yellow,
            createdAt: Date()
        )

        let third = try await cache.store(for: url)
        #expect(third !== first)
        let parsed = SwiftPDFAnnotationParser(storeCache: cache).parseAnnotations(in: third)
        #expect(parsed.count == 1)
        #expect(parsed.first?.contents == "External update")
    }

    @Test @MainActor
    func textOnlyAnnotationUpdateReusesExistingAppearanceStream() async throws {
        let dir = try makeTempDir("SwiftPDFReuseAP")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("reuse-ap.pdf")
        try writeBlankPDF(to: url)

        let cache = PDFDocumentStoreCache()
        let writer = SwiftPDFAnnotationWriter(storeCache: cache)
        let parser = SwiftPDFAnnotationParser(storeCache: cache)
        let initialColor = Annotation.Color(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.8)

        try await writer.createNote(
            in: url,
            location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 120, y: 240)),
            contents: "Initial",
            author: "Reviewer",
            color: initialColor,
            createdAt: Date()
        )

        let created = try #require(try await parser.annotations(in: url).first)
        let sourceID = try #require(created.sourceID)
        let objNum = try #require(SwiftPDFAnnotationWriter.parseObjectNumber(from: sourceID))

        let initialStore = try PDFDocumentStore(url: url)
        let initialAP = initialStore.object(number: objNum)?.dictValue?["AP"]?.dictValue?["N"]
        #expect(initialAP?.indirectRefValue != nil)

        // Updating contents with matching color & opacity should reuse the existing /AP /N stream.
        try await writer.update(
            in: url,
            sourceID: sourceID,
            contents: "Updated comment text",
            author: "Reviewer",
            color: created.color,
            modifiedAt: Date()
        )

        let afterTextStore = try PDFDocumentStore(url: url)
        let afterTextDict = try #require(afterTextStore.object(number: objNum)?.dictValue)
        let afterTextAP = afterTextDict["AP"]?.dictValue?["N"]
        #expect(afterTextAP == initialAP)
        #expect(afterTextDict["Contents"]?.textString == "Updated comment text")

        // Changing color should regenerate /AP /N.
        try await writer.update(
            in: url,
            sourceID: sourceID,
            contents: "Updated color text",
            author: "Reviewer",
            color: Annotation.Color(red: 0.9, green: 0.1, blue: 0.2, alpha: 0.8),
            modifiedAt: Date()
        )

        let afterColorStore = try PDFDocumentStore(url: url)
        let afterColorAP = afterColorStore.object(number: objNum)?.dictValue?["AP"]?.dictValue?["N"]
        #expect(afterColorAP?.indirectRefValue != nil)
        #expect(afterColorAP != initialAP)
    }

    @Test @MainActor
    func incrementalSuffixMatchesBuildDataAndSavesViaClone() async throws {
        let dir = try makeTempDir("SwiftPDFIncrementalClone")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clone.pdf")
        try writeBlankPDF(to: url)

        let store = try PDFDocumentStore(url: url)
        let page = try #require(store.pages().first)
        let writer = PDFIncrementalWriter(store: store)
        let annotRef = writer.allocateObject(.dict([
            "Type": .name("Annot"),
            "Subtype": .name("Text"),
            "Rect": .array([.real(40), .real(40), .real(60), .real(60)]),
            "P": .indirectRef(objNum: page.pageObjNum, genNum: page.pageGenNum),
            "Contents": .string(PDFTextString.encode("Cloned save note")),
            "T": .string(PDFTextString.encode("Tester"))
        ]))
        writer.appendAnnot(annotRef, to: page)

        let suffix = writer.buildIncrementalSuffix()
        let fullData = writer.buildData()
        #expect(!suffix.isEmpty)
        #expect(store.rawData + suffix == fullData)

        let writtenSuffix = try writer.saveIncrementally(to: url)
        #expect(writtenSuffix == suffix)

        let diskData = try Data(contentsOf: url)
        #expect(diskData == fullData)

        let parsed = try await SwiftPDFAnnotationParser(storeCache: PDFDocumentStoreCache()).annotations(in: url)
        #expect(parsed.count == 1)
        #expect(parsed.first?.contents == "Cloned save note")

        let pdfKitDoc = try #require(PDFDocument(url: url))
        #expect(pdfKitDoc.page(at: 0)?.annotations.count == 1)
    }
}
