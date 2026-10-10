import Foundation

/// Minimal DER (ASN.1) encoding, enough for a certificate signing request.
public enum DER {
    public static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var len = withUnsafeBytes(of: UInt64(n).bigEndian, Array.init)
            while len.first == 0 { len.removeFirst() }
            out.append(0x80 | UInt8(len.count))
            out.append(contentsOf: len)
        }
        out.append(content)
        return out
    }

    public static func sequence(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    public static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    public static func set(_ items: Data...) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    public static func integer(_ v: UInt8) -> Data { tlv(0x02, Data([v])) }
    public static func utf8String(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    public static func octetString(_ d: Data) -> Data { tlv(0x04, d) }
    /// A BIT STRING with no unused bits.
    public static func bitString(_ d: Data) -> Data { tlv(0x03, Data([0]) + d) }

    /// An OBJECT IDENTIFIER from its dotted form, e.g. `2.5.4.3`.
    public static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(parts.count >= 2, "invalid OID \(dotted)")
        var body = Data(base128(parts[0] * 40 + parts[1]))
        for p in parts.dropFirst(2) { body.append(contentsOf: base128(p)) }
        return tlv(0x06, body)
    }

    private static func base128(_ v: UInt64) -> [UInt8] {
        var out = [UInt8(v & 0x7F)]
        var rest = v >> 7
        while rest > 0 {
            out.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return out
    }
}

/// A PKCS #10 certificate signing request for an ECDSA P-256 key, with the
/// host names as subject alternative names (as Cloudflare's Origin CA
/// expects). Signing is left to the caller (CryptoKit in the app), so the
/// private key never passes through here.
public enum CSR {
    static let commonName = "2.5.4.3"
    static let extensionRequest = "1.2.840.113549.1.9.14"
    static let subjectAltName = "2.5.29.17"
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"

    /// The `CertificationRequestInfo` to sign. [publicKey] is the
    /// SubjectPublicKeyInfo DER (CryptoKit's `derRepresentation`).
    public static func requestInfo(commonName cn: String, hostnames: [String], publicKey: Data) -> Data {
        let subject = DER.sequence(DER.set(DER.sequence(DER.oid(commonName), DER.utf8String(cn))))
        // GeneralName dNSName is [2] IMPLICIT IA5String.
        let names = DER.sequence(hostnames.map { DER.tlv(0x82, Data($0.utf8)) })
        let extensions = DER.sequence(DER.sequence(DER.oid(subjectAltName), DER.octetString(names)))
        let attribute = DER.sequence(DER.oid(extensionRequest), DER.set(extensions))
        let attributes = DER.tlv(0xA0, attribute)
        return DER.sequence(DER.integer(0), subject, publicKey, attributes)
    }

    /// The complete request from its info and the DER ECDSA signature over it.
    public static func assemble(info: Data, signature: Data) -> Data {
        DER.sequence(info, DER.sequence(DER.oid(ecdsaWithSHA256)), DER.bitString(signature))
    }

    /// Builds and signs a request: [sign] gets the bytes to sign and returns
    /// a DER-encoded ECDSA-SHA256 signature.
    public static func make(
        hostnames: [String], publicKey: Data, sign: (Data) throws -> Data
    ) rethrows -> String {
        let info = requestInfo(commonName: hostnames.first ?? "", hostnames: hostnames, publicKey: publicKey)
        return pem(assemble(info: info, signature: try sign(info)), label: "CERTIFICATE REQUEST")
    }

    /// PEM armour with 64-character lines.
    public static func pem(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }
}
