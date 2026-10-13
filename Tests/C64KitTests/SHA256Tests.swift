@testable import C64Kit
import CryptoKit
import Testing

/// The portable SHA-256 (the disk validation and crack detection on every platform) and the hex
/// formatting that replaces `String(format:)`.
struct SHA256Tests {
    /// The FIPS 180-4 examples.
    @Test func knownDigests() {
        #expect(hexString(SHA2.sha256([UInt8]())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hexString(SHA2.sha256(Array("abc".utf8)))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hexString(SHA2.sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// Against CryptoKit at every length around the padding boundaries and at the block size.
    @Test func matchesCryptoKit() {
        var rng = SystemRandomNumberGenerator()
        for length in Array(0...200) + [1023, 1024, 1025, 4096] {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            #expect(SHA2.sha256(bytes) == Array(SHA256.hash(data: bytes)), "length \(length)")
        }
    }

    @Test func hexFormatting() {
        #expect(hex(0xA7E2, width: 4) == "A7E2")
        #expect(hex(UInt8(0x0B)) == "0B")
        #expect(hex(0x34, width: 4) == "0034")
        #expect(hex(UInt64(0xDEAD_BEEF_0000_0001), width: 16) == "DEADBEEF00000001")
        #expect(hex(0x12345, width: 4) == "12345")
        #expect(hexString([0x00, 0x0F, 0xA0, 0xFF]) == "000fa0ff")
    }
}
