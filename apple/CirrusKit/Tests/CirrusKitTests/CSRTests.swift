import Foundation
import Testing
@testable import CirrusKit

@Suite struct CSRTests {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    @Test func objectIdentifiers() {
        #expect(hex(DER.oid("1.2.840.10045.2.1")) == "06072a8648ce3d0201")
        #expect(hex(DER.oid("2.5.29.17")) == "0603551d11")
        #expect(hex(DER.oid("1.2.840.113549.1.9.14")) == "06092a864886f70d01090e")
        #expect(hex(DER.oid("1.2.840.10045.4.3.2")) == "06082a8648ce3d040302")
    }

    @Test func lengths() {
        #expect(hex(DER.octetString(Data(repeating: 0, count: 3))) == "0403000000")
        #expect(DER.octetString(Data(repeating: 0, count: 200)).prefix(3) == Data([0x04, 0x81, 200]))
        #expect(DER.octetString(Data(repeating: 0, count: 300)).prefix(4) == Data([0x04, 0x82, 0x01, 0x2C]))
    }

    @Test func requestLayout() {
        let spki = DER.sequence(DER.oid("1.2.840.10045.2.1"), DER.bitString(Data(repeating: 4, count: 65)))
        var signed: Data?
        let pem = CSR.make(hostnames: ["example.com", "*.example.com"], publicKey: spki) { info in
            signed = info
            return DER.sequence(DER.integer(1), DER.integer(2))
        }
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\n"))
        #expect(pem.hasSuffix("-----END CERTIFICATE REQUEST-----\n"))
        #expect(pem.split(separator: "\n").allSatisfy { $0.count <= 64 || $0.hasPrefix("-----") })
        let info = try! #require(signed)
        #expect(info.first == 0x30)
        #expect(info.range(of: Data("*.example.com".utf8)) != nil)
        #expect(info.range(of: spki) != nil)
    }
}
