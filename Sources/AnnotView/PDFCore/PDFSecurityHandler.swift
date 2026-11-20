import CommonCrypto
import CryptoKit
import Foundation

enum PDFSecurityError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFilter(String)
    case unsupportedVersion(v: Int, r: Int)
    case unsupportedCryptFilter(String)
    case missingRequiredEntry(String)
    case invalidEntry(String)
    case passwordRequired
    case cryptoFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFilter(let filter):
            return "Unsupported PDF security filter: /\(filter)"
        case .unsupportedVersion(let v, let r):
            return "Unsupported PDF encryption version /V \(v) /R \(r)"
        case .unsupportedCryptFilter(let method):
            return "Unsupported PDF crypt filter method: /\(method)"
        case .missingRequiredEntry(let key):
            return "Missing required /\(key) entry in /Encrypt dictionary"
        case .invalidEntry(let detail):
            return "Invalid /Encrypt dictionary entry: \(detail)"
        case .passwordRequired:
            return "This PDF requires a password to open"
        case .cryptoFailure(let detail):
            return "PDF cryptographic operation failed: \(detail)"
        }
    }
}

/// Pure-Swift ISO 32000-1 / 32000-2 Standard Security Handler (`/Filter /Standard`).
/// Supports `/V` 1, 2, 4, 5 and `/R` 2, 3, 4, 5, 6 (RC4-40, RC4-128, AES-128-CBC, AES-256-CBC).
struct PDFSecurityHandler: Sendable {
    enum CryptMethod: Equatable, Sendable {
        case none
        case rc4
        case aes128
        case aes256
    }

    /// Standard 32-byte password padding string (ISO 32000-1 §7.6.3.3).
    static let standardPadding: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41,
        0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
        0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A
    ]

    let version: Int
    let revision: Int
    let encryptMetadata: Bool
    let permissions: Int32
    let fileEncryptionKey: Data
    let stringMethod: CryptMethod
    let streamMethod: CryptMethod

    init(encryptDict: [String: PDFObject], fileID: Data?, password: String = "") throws {
        // 1. Validate /Filter
        if let filter = encryptDict["Filter"]?.nameValue, filter != "Standard" {
            throw PDFSecurityError.unsupportedFilter(filter)
        }

        // 2. Parse /V and /R
        let v = encryptDict["V"]?.intValue ?? 0
        guard let r = encryptDict["R"]?.intValue else {
            throw PDFSecurityError.missingRequiredEntry("R")
        }
        guard [1, 2, 4, 5].contains(v), [2, 3, 4, 5, 6].contains(r) else {
            throw PDFSecurityError.unsupportedVersion(v: v, r: r)
        }
        self.version = v
        self.revision = r

        // 3. Parse /P and /EncryptMetadata
        guard let rawP = encryptDict["P"]?.int64Value else {
            throw PDFSecurityError.missingRequiredEntry("P")
        }
        let pBits = UInt32(truncatingIfNeeded: rawP)
        self.permissions = Int32(bitPattern: pBits)

        if r >= 4 {
            self.encryptMetadata = encryptDict["EncryptMetadata"]?.boolValue ?? true
        } else {
            self.encryptMetadata = true
        }

        // 4. Determine crypt methods and key length in bytes
        let (strMethod, stmMethod, keyLengthBytes) = try Self.resolveCryptMethods(
            encryptDict: encryptDict,
            version: v,
            revision: r
        )
        self.stringMethod = strMethod
        self.streamMethod = stmMethod

        // 5. Authenticate password and derive file encryption key
        guard let oData = encryptDict["O"]?.stringData else {
            throw PDFSecurityError.missingRequiredEntry("O")
        }
        guard let uData = encryptDict["U"]?.stringData else {
            throw PDFSecurityError.missingRequiredEntry("U")
        }

        if r <= 4 {
            guard oData.count >= 32 else {
                throw PDFSecurityError.invalidEntry("/O must be at least 32 bytes for R=\(r)")
            }
            let minULen = (r == 2) ? 32 : 16
            guard uData.count >= minULen else {
                throw PDFSecurityError.invalidEntry("/U must be at least \(minULen) bytes for R=\(r)")
            }

            let oBytes = Data(oData.prefix(32))
            let uBytes = Data(uData.prefix(32))
            let pwdBytes = Data(password.utf8)

            // Try as user password first (Algorithm 6)
            if let key = Self.authenticateUserR2to4(
                password: pwdBytes,
                oValue: oBytes,
                uValue: uBytes,
                pBits: pBits,
                fileID: fileID,
                keyLengthBytes: keyLengthBytes,
                revision: r,
                encryptMetadata: self.encryptMetadata
            ) {
                self.fileEncryptionKey = key
            } else if let key = Self.authenticateOwnerR2to4(
                password: pwdBytes,
                oValue: oBytes,
                uValue: uBytes,
                pBits: pBits,
                fileID: fileID,
                keyLengthBytes: keyLengthBytes,
                revision: r,
                encryptMetadata: self.encryptMetadata
            ) {
                self.fileEncryptionKey = key
            } else {
                throw PDFSecurityError.passwordRequired
            }
        } else {
            // R == 5 or R == 6 (AES-256)
            guard uData.count >= 48 else {
                throw PDFSecurityError.invalidEntry("/U must be at least 48 bytes for R=\(r)")
            }
            let ueData = encryptDict["UE"]?.stringData
            let oeData = encryptDict["OE"]?.stringData
            let pwdBytes = Data(password.utf8.prefix(127))

            if let key = try Self.authenticateR5R6(
                password: pwdBytes,
                revision: r,
                uValue: uData,
                oValue: oData,
                ueValue: ueData,
                oeValue: oeData
            ) {
                self.fileEncryptionKey = key
            } else {
                throw PDFSecurityError.passwordRequired
            }
        }
    }

    // MARK: - Public Encrypt / Decrypt API

    func decryptString(_ data: Data, objNum: Int, genNum: Int) -> Data {
        decrypt(data, method: stringMethod, objNum: objNum, genNum: genNum)
    }

    func decryptStream(_ data: Data, objNum: Int, genNum: Int) -> Data {
        decrypt(data, method: streamMethod, objNum: objNum, genNum: genNum)
    }

    func encryptString(_ data: Data, objNum: Int, genNum: Int) -> Data {
        encrypt(data, method: stringMethod, objNum: objNum, genNum: genNum)
    }

    func encryptStream(_ data: Data, objNum: Int, genNum: Int) -> Data {
        encrypt(data, method: streamMethod, objNum: objNum, genNum: genNum)
    }

    // MARK: - Crypt Method Resolution

    private static func resolveCryptMethods(
        encryptDict: [String: PDFObject],
        version: Int,
        revision: Int
    ) throws -> (stringMethod: CryptMethod, streamMethod: CryptMethod, keyLengthBytes: Int) {
        if version == 1 {
            return (.rc4, .rc4, 5)
        }
        if version == 2 {
            let bits = encryptDict["Length"]?.intValue ?? 40
            let bytes = max(5, min(16, bits / 8))
            return (.rc4, .rc4, bytes)
        }

        // V == 4 or V == 5: consult /CF, /StmF, /StrF
        let cfDict = encryptDict["CF"]?.dictValue ?? [:]
        let stmFilterName = encryptDict["StmF"]?.nameValue ?? "Identity"
        let strFilterName = encryptDict["StrF"]?.nameValue ?? "Identity"

        let (stmMethod, stmCFKeyBytes) = try resolveSingleCryptFilter(
            name: stmFilterName,
            cfDict: cfDict
        )
        let (strMethod, strCFKeyBytes) = try resolveSingleCryptFilter(
            name: strFilterName,
            cfDict: cfDict
        )

        if version == 5 || revision >= 5 {
            return (strMethod, stmMethod, 32)
        }

        // V == 4 key length resolution (handle both bytes < 40 and bits >= 40 in /CF /Length)
        let keyBytes: Int
        if let cfLen = stmCFKeyBytes ?? strCFKeyBytes {
            keyBytes = cfLen
        } else if let topBits = encryptDict["Length"]?.intValue {
            keyBytes = topBits < 40 ? topBits : (topBits / 8)
        } else {
            keyBytes = 16
        }
        return (strMethod, stmMethod, max(5, min(16, keyBytes)))
    }

    private static func resolveSingleCryptFilter(
        name: String,
        cfDict: [String: PDFObject]
    ) throws -> (method: CryptMethod, keyLengthBytes: Int?) {
        if name == "Identity" {
            return (.none, nil)
        }
        guard let filterDict = cfDict[name]?.dictValue else {
            throw PDFSecurityError.unsupportedCryptFilter(name)
        }
        let cfm = filterDict["CFM"]?.nameValue ?? "None"
        let method: CryptMethod
        switch cfm {
        case "None":
            method = .none
        case "V2":
            method = .rc4
        case "AESV2":
            method = .aes128
        case "AESV3":
            method = .aes256
        default:
            throw PDFSecurityError.unsupportedCryptFilter(cfm)
        }

        var keyLenBytes: Int?
        if let rawLen = filterDict["Length"]?.intValue, rawLen > 0 {
            // Adobe PDF 1.6/1.7 writes /Length in bytes (16 or 32) inside /CF,
            // while ISO 32000-1 Table 25 says bits (40..128). Support both.
            keyLenBytes = rawLen < 40 ? rawLen : (rawLen / 8)
        }
        return (method, keyLenBytes)
    }

    // MARK: - Core Per-Object Encryption / Decryption

    private func decrypt(_ data: Data, method: CryptMethod, objNum: Int, genNum: Int) -> Data {
        switch method {
        case .none:
            return data
        case .rc4:
            guard !data.isEmpty else { return data }
            let objKey = deriveObjectKey(objNum: objNum, genNum: genNum, isAES: false)
            return Self.rc4(key: objKey, data: data)
        case .aes128:
            let objKey = deriveObjectKey(objNum: objNum, genNum: genNum, isAES: true)
            return Self.aesDecryptWithIVPrefix(data: data, key: objKey)
        case .aes256:
            return Self.aesDecryptWithIVPrefix(data: data, key: fileEncryptionKey)
        }
    }

    private func encrypt(_ data: Data, method: CryptMethod, objNum: Int, genNum: Int) -> Data {
        switch method {
        case .none:
            return data
        case .rc4:
            guard !data.isEmpty else { return data }
            let objKey = deriveObjectKey(objNum: objNum, genNum: genNum, isAES: false)
            return Self.rc4(key: objKey, data: data)
        case .aes128:
            let objKey = deriveObjectKey(objNum: objNum, genNum: genNum, isAES: true)
            return Self.aesEncryptWithIVPrefix(data: data, key: objKey)
        case .aes256:
            return Self.aesEncryptWithIVPrefix(data: data, key: fileEncryptionKey)
        }
    }

    /// ISO 32000-1 §7.6.2 Algorithm 1: per-object key derivation for RC4 and AES-128.
    private func deriveObjectKey(objNum: Int, genNum: Int, isAES: Bool) -> Data {
        var input = Data()
        input.reserveCapacity(fileEncryptionKey.count + 9)
        input.append(fileEncryptionKey)
        input.append(UInt8(objNum & 0xFF))
        input.append(UInt8((objNum >> 8) & 0xFF))
        input.append(UInt8((objNum >> 16) & 0xFF))
        input.append(UInt8(genNum & 0xFF))
        input.append(UInt8((genNum >> 8) & 0xFF))
        if isAES {
            // "sAlT"
            input.append(contentsOf: [0x73, 0x41, 0x6C, 0x54])
        }
        let digest = Self.md5(input)
        let outLen = min(fileEncryptionKey.count + 5, 16)
        return Data(digest.prefix(outLen))
    }

    // MARK: - R = 2, 3, 4 Key Derivation & Authentication (Algorithms 2, 3, 4, 5, 6, 7)

    private static func padPassword(_ password: Data) -> Data {
        var padded = Data(password.prefix(32))
        if padded.count < 32 {
            padded.append(contentsOf: standardPadding.prefix(32 - padded.count))
        }
        return padded
    }

    /// Algorithm 2: Computing an encryption key (R = 2, 3, 4).
    static func computeEncryptionKeyR2to4(
        password: Data,
        oValue: Data,
        pBits: UInt32,
        fileID: Data?,
        keyLengthBytes: Int,
        revision: Int,
        encryptMetadata: Bool
    ) -> Data {
        let padded = padPassword(password)
        var input = Data()
        input.reserveCapacity(32 + 32 + 4 + (fileID?.count ?? 0) + 4)
        input.append(padded)
        input.append(oValue.prefix(32))
        input.append(UInt8(pBits & 0xFF))
        input.append(UInt8((pBits >> 8) & 0xFF))
        input.append(UInt8((pBits >> 16) & 0xFF))
        input.append(UInt8((pBits >> 24) & 0xFF))
        if let fileID, !fileID.isEmpty {
            input.append(fileID)
        }
        if revision >= 4 && !encryptMetadata {
            input.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        }

        var hash = md5(input)
        let n = (revision == 2) ? 5 : keyLengthBytes
        if revision >= 3 {
            for _ in 0..<50 {
                hash = md5(Data(hash.prefix(n)))
            }
        }
        return Data(hash.prefix(n))
    }

    /// Algorithms 4, 5, 6: Authenticate user password for R = 2, 3, 4.
    private static func authenticateUserR2to4(
        password: Data,
        oValue: Data,
        uValue: Data,
        pBits: UInt32,
        fileID: Data?,
        keyLengthBytes: Int,
        revision: Int,
        encryptMetadata: Bool
    ) -> Data? {
        let key = computeEncryptionKeyR2to4(
            password: password,
            oValue: oValue,
            pBits: pBits,
            fileID: fileID,
            keyLengthBytes: keyLengthBytes,
            revision: revision,
            encryptMetadata: encryptMetadata
        )

        if revision == 2 {
            // Algorithm 4
            let computed = rc4(key: key, data: Data(standardPadding))
            return computed == Data(uValue.prefix(32)) ? key : nil
        } else {
            // Algorithm 5
            var hashInput = Data(standardPadding)
            if let fileID, !fileID.isEmpty {
                hashInput.append(fileID)
            }
            var result = rc4(key: key, data: md5(hashInput))
            let keyBytes = Array(key)
            for i in UInt8(1)...UInt8(19) {
                let iterKey = Data(keyBytes.map { $0 ^ i })
                result = rc4(key: iterKey, data: result)
            }
            return result == Data(uValue.prefix(16)) ? key : nil
        }
    }

    /// Algorithms 3 & 7: Authenticate owner password for R = 2, 3, 4.
    private static func authenticateOwnerR2to4(
        password: Data,
        oValue: Data,
        uValue: Data,
        pBits: UInt32,
        fileID: Data?,
        keyLengthBytes: Int,
        revision: Int,
        encryptMetadata: Bool
    ) -> Data? {
        let padded = padPassword(password)
        var hash = md5(padded)
        if revision >= 3 {
            for _ in 0..<50 {
                hash = md5(hash)
            }
        }
        let n = (revision == 2) ? 5 : keyLengthBytes
        let rc4Key = Data(hash.prefix(n))

        var decryptedUserPwd: Data
        if revision == 2 {
            decryptedUserPwd = rc4(key: rc4Key, data: Data(oValue.prefix(32)))
        } else {
            decryptedUserPwd = Data(oValue.prefix(32))
            let keyBytes = Array(rc4Key)
            for i in (0...19).reversed() {
                let xorByte = UInt8(i)
                let iterKey = Data(keyBytes.map { $0 ^ xorByte })
                decryptedUserPwd = rc4(key: iterKey, data: decryptedUserPwd)
            }
        }

        return authenticateUserR2to4(
            password: decryptedUserPwd,
            oValue: oValue,
            uValue: uValue,
            pBits: pBits,
            fileID: fileID,
            keyLengthBytes: keyLengthBytes,
            revision: revision,
            encryptMetadata: encryptMetadata
        )
    }

    // MARK: - R = 5, 6 Key Derivation & Authentication (ISO 32000-2 Algorithms 2.A & 2.B)

    private static func authenticateR5R6(
        password: Data,
        revision: Int,
        uValue: Data,
        oValue: Data,
        ueValue: Data?,
        oeValue: Data?
    ) throws -> Data? {
        let uBytes = Array(uValue)
        let uHash = Data(uBytes[0..<32])
        let uValidationSalt = Data(uBytes[32..<40])
        let uKeySalt = Data(uBytes[40..<48])
        let zeroIV = Data(repeating: 0, count: 16)

        // 1. Check user password
        let computedUHash = try computeHashR5R6(
            password: password,
            salt: uValidationSalt,
            uKey: Data(),
            revision: revision
        )
        if computedUHash == uHash {
            guard let ueValue, ueValue.count == 32 else {
                throw PDFSecurityError.missingRequiredEntry("UE")
            }
            let intermediateKey = try computeHashR5R6(
                password: password,
                salt: uKeySalt,
                uKey: Data(),
                revision: revision
            )
            return try aesCBC(
                operation: CCOperation(kCCDecrypt),
                key: intermediateKey,
                iv: zeroIV,
                data: ueValue,
                pkcs7Padding: false
            )
        }

        // 2. Check owner password
        if oValue.count >= 48, let oeValue, oeValue.count == 32 {
            let oBytes = Array(oValue)
            let oHash = Data(oBytes[0..<32])
            let oValidationSalt = Data(oBytes[32..<40])
            let oKeySalt = Data(oBytes[40..<48])
            let uKey48 = Data(uBytes[0..<48])

            let computedOHash = try computeHashR5R6(
                password: password,
                salt: oValidationSalt,
                uKey: uKey48,
                revision: revision
            )
            if computedOHash == oHash {
                let intermediateKey = try computeHashR5R6(
                    password: password,
                    salt: oKeySalt,
                    uKey: uKey48,
                    revision: revision
                )
                return try aesCBC(
                    operation: CCOperation(kCCDecrypt),
                    key: intermediateKey,
                    iv: zeroIV,
                    data: oeValue,
                    pkcs7Padding: false
                )
            }
        }

        return nil
    }

    /// Computes the 32-byte hash for R = 5 (single SHA-256) or R = 6 (ISO 32000-2 Algorithm 2.B).
    static func computeHashR5R6(
        password: Data,
        salt: Data,
        uKey: Data,
        revision: Int
    ) throws -> Data {
        var initial = Data()
        initial.reserveCapacity(password.count + salt.count + uKey.count)
        initial.append(password)
        initial.append(salt)
        initial.append(uKey)

        var k = sha256(initial)
        if revision == 5 {
            return k
        }

        // R == 6: ISO 32000-2 §7.6.4.3.3 Algorithm 2.B
        var round = 0
        var lastByte: UInt8 = 0
        repeat {
            let chunkLen = password.count + k.count + uKey.count
            var k1 = Data()
            k1.reserveCapacity(chunkLen * 64)
            var chunk = Data()
            chunk.reserveCapacity(chunkLen)
            chunk.append(password)
            chunk.append(k)
            chunk.append(uKey)
            for _ in 0..<64 {
                k1.append(chunk)
            }

            let aesKey = Data(k.prefix(16))
            let aesIV = Data(k[k.index(k.startIndex, offsetBy: 16)..<k.index(k.startIndex, offsetBy: 32)])
            let e = try aesCBC(
                operation: CCOperation(kCCEncrypt),
                key: aesKey,
                iv: aesIV,
                data: k1,
                pkcs7Padding: false
            )

            // Big-endian first 16 bytes of E mod 3.
            // Since 256 ≡ 1 (mod 3), sum of bytes mod 3 equals big-endian integer mod 3.
            var sumMod3 = 0
            e.withUnsafeBytes { buf in
                let ptr = buf.bindMemory(to: UInt8.self)
                for idx in 0..<16 {
                    sumMod3 += Int(ptr[idx])
                }
            }
            switch sumMod3 % 3 {
            case 0:
                k = sha256(e)
            case 1:
                k = sha384(e)
            default:
                k = sha512(e)
            }

            lastByte = e[e.index(before: e.endIndex)]
            round += 1
        } while round < 64 || Int(lastByte) > round - 32

        return Data(k.prefix(32))
    }

    // MARK: - Cryptographic Primitives

    /// Pure-Swift RC4 (KSA + PRGA). Symmetric for encrypt and decrypt.
    static func rc4(key: Data, data: Data) -> Data {
        guard !key.isEmpty, !data.isEmpty else { return data }
        var s = [UInt8](0...255)
        let keyBytes = Array(key)
        let keyCount = keyBytes.count
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(keyBytes[i % keyCount])) & 0xFF
            s.swapAt(i, j)
        }

        var output = Data(count: data.count)
        var i = 0
        j = 0
        output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                let outPtr = outBuf.bindMemory(to: UInt8.self)
                let inPtr = inBuf.bindMemory(to: UInt8.self)
                for idx in 0..<data.count {
                    i = (i + 1) & 0xFF
                    j = (j + Int(s[i])) & 0xFF
                    s.swapAt(i, j)
                    let k = s[(Int(s[i]) + Int(s[j])) & 0xFF]
                    outPtr[idx] = inPtr[idx] ^ k
                }
            }
        }
        return output
    }

    private static func aesDecryptWithIVPrefix(data: Data, key: Data) -> Data {
        guard data.count > 16 else { return Data() }
        let iv = Data(data.prefix(16))
        let rawCiphertext = data.dropFirst(16)
        let alignedCount = (rawCiphertext.count / 16) * 16
        guard alignedCount > 0 else { return Data() }
        let ciphertext = Data(rawCiphertext.prefix(alignedCount))

        if let decrypted = try? aesCBC(
            operation: CCOperation(kCCDecrypt),
            key: key,
            iv: iv,
            data: ciphertext,
            pkcs7Padding: true
        ) {
            return decrypted
        }

        // Fallback if a real-world PDF has non-standard/corrupt PKCS7 padding:
        // decrypt raw blocks and strip valid PKCS7 padding if present.
        if let raw = try? aesCBC(
            operation: CCOperation(kCCDecrypt),
            key: key,
            iv: iv,
            data: ciphertext,
            pkcs7Padding: false
        ) {
            if let last = raw.last, last >= 1, last <= 16, raw.count >= Int(last) {
                let padStart = raw.count - Int(last)
                let isValidPad = raw[raw.index(raw.startIndex, offsetBy: padStart)...].allSatisfy { $0 == last }
                if isValidPad {
                    return Data(raw.prefix(padStart))
                }
            }
            return raw
        }

        return Data()
    }

    private static func aesEncryptWithIVPrefix(data: Data, key: Data) -> Data {
        let iv = randomIV()
        guard let ciphertext = try? aesCBC(
            operation: CCOperation(kCCEncrypt),
            key: key,
            iv: iv,
            data: data,
            pkcs7Padding: true
        ) else {
            return Data()
        }
        var result = Data(capacity: 16 + ciphertext.count)
        result.append(iv)
        result.append(ciphertext)
        return result
    }

    private static func aesCBC(
        operation: CCOperation,
        key: Data,
        iv: Data,
        data: Data,
        pkcs7Padding: Bool
    ) throws -> Data {
        let options: CCOptions = pkcs7Padding ? CCOptions(kCCOptionPKCS7Padding) : 0
        let outCapacity = data.count + kCCBlockSizeAES128
        var outData = Data(count: outCapacity)
        var numBytesProcessed: size_t = 0
        let emptyByte: UInt8 = 0

        let status: CCCryptorStatus = withUnsafePointer(to: emptyByte) { emptyPtr in
            outData.withUnsafeMutableBytes { outBuf in
                data.withUnsafeBytes { dataBuf in
                    key.withUnsafeBytes { keyBuf in
                        iv.withUnsafeBytes { ivBuf in
                            CCCrypt(
                                operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBuf.baseAddress,
                                key.count,
                                ivBuf.baseAddress,
                                dataBuf.baseAddress ?? UnsafeRawPointer(emptyPtr),
                                data.count,
                                outBuf.baseAddress,
                                outCapacity,
                                &numBytesProcessed
                            )
                        }
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw PDFSecurityError.cryptoFailure("CCCrypt failed with status \(status)")
        }
        outData.count = numBytesProcessed
        return outData
    }

    private static func randomIV() -> Data {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return Data(bytes)
    }

    private static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func sha384(_ data: Data) -> Data {
        Data(SHA384.hash(data: data))
    }

    private static func sha512(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }
}
