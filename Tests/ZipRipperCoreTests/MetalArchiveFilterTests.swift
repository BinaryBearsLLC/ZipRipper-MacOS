import XCTest
@testable import ZipRipperCore

final class MetalArchiveFilterTests: XCTestCase {
    func testIndependentSHA256ArchiveVectors() throws {
        let gpu = try MetalArchiveFilter()
        print("Metal archive known-answer device: \(gpu.deviceName)")
        // Generated independently with Python hashlib, openssl AES-CBC and
        // Python lzma. 7z padding is deliberately NONZERO to ensure we use CRC.
        let vectors: [(String, String)] = [
            ("password", "$7z$0$13$0$$16$00000000000000000000000000000000$2507884111$32$26$f1901df82d05d29a91182537591bd491f6d222ff8ffd9024d07b8b69d856f2b1"),
            ("", "$7z$0$13$0$$16$00000000000000000000000000000000$2507884111$32$26$4c3527970060947837a26562a83f75560b1dc39914a8812af71c540a2d0fb74e"),
            ("päss🔑", "$7z$0$13$0$$16$00000000000000000000000000000000$2507884111$32$26$7790cf3652a45a7a06841cdf63885c8986df7459e7a9b1b21698ea8007cd2c0c"),
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaa", "$7z$0$13$0$$16$00000000000000000000000000000000$2507884111$32$26$0423c2d3be3029ef8f1a10eef6bef6d52ff0630bde7d213c89ce7c0f5974943e"),
            ("password", "$7z$2$13$0$$16$00000000000000000000000000000000$3732169750$64$62$5b575c350e875eb13395350f64992d99adc6d2d5ae45b001710290baf32f810b957825809f218f51a4461e1c6dc04edf6029686cb6057561400a0a76cf28f7ad$880$00"),
            ("password", "$rar5$16$000102030405060708090a0b0c0d0e0f$0$00000000000000000000000000000000$8$e687d44db814b12a"),
            ("päss🔑", "$rar5$16$000102030405060708090a0b0c0d0e0f$12$00000000000000000000000000000000$8$d2ebf0dc170a84f1"),
            ("", "$rar5$16$000102030405060708090a0b0c0d0e0f$15$00000000000000000000000000000000$8$06c421403eee7d2a"),
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "$rar5$16$000102030405060708090a0b0c0d0e0f$12$00000000000000000000000000000000$8$fa6e23f06ea92d8f"),
            ("password", "$pdf$5*5*256*-4*1*0**48*ab47a551c847884819019c30e7b50cb3a26df8be39fbbf3943c61c5547fc55f700010203040506070000000000000000*48*000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
            ("", "$pdf$5*5*256*-4*1*0**48*8a851ff82ee7048ad09ec3847f1ddf44944104d2cbd17ef4e3db22c6785a0d4500010203040506070000000000000000*48*000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
            ("päss🔑", "$pdf$5*5*256*-4*1*0**48*d1f4c31ea6660dfce22fc13102469305bf3d1fa4624d05de0aa8e3f362be33b700010203040506070000000000000000*48*000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"),
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "$pdf$5*5*256*-4*1*0**48*930c261f1564ca43b0f1a6fb90c46fd50d18ba0f68b38bc1d95e8db416f7103b00010203040506070000000000000000*48*000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
        ]
        let classic: [(String, String)] = [
            ("password", "$pkzip$1*2*1*0*8*c*1234*ee10ed7753936e6b5c662a7b*$/pkzip$"),
            ("password", "$pkzip2$1*2*1*0*8*c*5678*1234*ee10ed7753936e6b5c662a7b*$/pkzip2$"),
            ("", "$pkzip$1*2*1*0*8*c*1234*ab1b61579be247098beebe42*$/pkzip$"),
            ("", "$pkzip2$1*2*1*0*8*c*5678*1234*ab1b61579be247098beebe42*$/pkzip2$"),
            ("päss🔑", "$pkzip$1*2*1*0*8*c*1234*360347077cd90361355a12d4*$/pkzip$"),
            ("päss🔑", "$pkzip2$1*2*1*0*8*c*5678*1234*360347077cd90361355a12d4*$/pkzip2$")
        ]
        for (password, hash) in vectors + classic {
            XCTAssertTrue(MetalArchiveFilter.supports(hashLine: hash), hash)
            XCTAssertEqual(try gpu.filter(candidates: ["wrong", password, "incorrect"], hashLine: hash), [password], hash)
        }
    }
    func testIndependentRAR3AndLegacyPDFVectors() throws {
        let gpu = try MetalArchiveFilter()
        // Python hashlib SHA1/MD5 + independent RC4 + openssl AES-CBC.
        let vectors: [(String, String)] = [
            ("password", "$RAR3$*0*0001020304050607*0b8ff2090e12050e23666188f89702b9"),
            ("password", "$RAR3$*1*0001020304050607*1ab660fa*32*30*1*6a16339f7f09e6d9d9bc8df44103b3cabb22e6a68ef6cf61f6348f9b147deb57*30"),
            ("", "$RAR3$*0*0001020304050607*64c807e8105c56a8fd1a3a86ff1c9a76"),
            ("", "$RAR3$*1*0001020304050607*1ab660fa*32*30*1*a1d4d21058eb2e26f99d9b28681f4a645abed527544429475fa1bf92fcd6e7a8*30"),
            ("päss🔑", "$RAR3$*0*0001020304050607*796520f4c5733b902da9aeb586c12e8b"),
            ("päss🔑", "$RAR3$*1*0001020304050607*1ab660fa*32*30*1*d6fa151c4e5d68cb7ebcb02992f460fbe225543c0e251074d09b29366ad7f854*30"),
            ("password", "$pdf$1*2*40*-4*1*16*000102030405060708090a0b0c0d0e0f*32*643b0453a04a7d8b5f1628b628924541521f71db71b23660d2296d55ab8b7b31*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("", "$pdf$1*2*40*-4*1*16*000102030405060708090a0b0c0d0e0f*32*bdfd2ba69eb485e8958f00573637472252fc32a0a02880b2f522a7337b796732*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("päss🔑", "$pdf$1*2*40*-4*1*16*000102030405060708090a0b0c0d0e0f*32*ac0ce927bc56e8aadfda05e6d82338733b8935392ac923db71426c980524d5eb*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("password", "$pdf$4*3*40*-4*1*16*000102030405060708090a0b0c0d0e0f*32*6da0a3691cb597aacc8faf747351385b00000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("", "$pdf$4*3*40*-4*1*16*000102030405060708090a0b0c0d0e0f*32*e8de3738cfac9259ade9c410ae3fbf3400000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("päss🔑", "$pdf$4*3*40*-4*1*16*000102030405060708090a0b0c0d0e0f*32*7cb9ef7949ee5a14adac86eb7797a52a00000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("password", "$pdf$4*3*128*-4*1*16*000102030405060708090a0b0c0d0e0f*32*55eb7a028de94501c640f79a4f5657a600000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("", "$pdf$4*3*128*-4*1*16*000102030405060708090a0b0c0d0e0f*32*cf8fbebf7e094e114577a5b4a8b2fd5c00000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("päss🔑", "$pdf$4*3*128*-4*1*16*000102030405060708090a0b0c0d0e0f*32*a1c2dc771cf64e9f50bb9b5b33f79bde00000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("password", "$pdf$4*4*128*-4*0*16*000102030405060708090a0b0c0d0e0f*32*49a46a7f3c37f600a256c51309065c8a00000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("", "$pdf$4*4*128*-4*0*16*000102030405060708090a0b0c0d0e0f*32*a6bc1b14832ca7b1a06c84c0e4eb46e800000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
            ("päss🔑", "$pdf$4*4*128*-4*0*16*000102030405060708090a0b0c0d0e0f*32*90475cb9d0e1c64daa25cf7317a5d2cf00000000000000000000000000000000*32*000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        ]
        for (password, hash) in vectors {
            XCTAssertTrue(MetalArchiveFilter.supports(hashLine: hash), hash)
            XCTAssertEqual(try gpu.filter(candidates: ["wrong", password, "incorrect"], hashLine: hash), [password], hash)
        }
    }
    func testRAR3CompressedAndSplitKDFCancellation() throws {
        let gpu = try MetalArchiveFilter()
        // John's independently published RAR3 -m3 vector, password "test".
        let hash = "$RAR3$*1*b4eee1a48dc95d12*965f1453*64*47*1*0fe529478798c0960dd88a38a05451f9559e15f0cf20b4cac58260b0e5b56699d5871bdcc35bee099cc131eb35b9a116adaedf5ecc26b1c09cadf5185b3092e6*33"
        XCTAssertTrue(MetalArchiveFilter.supports(hashLine: hash))
        let candidates = (0..<32).map { "wrong-\($0)" } + ["test"]
        let result = try gpu.filter(candidates: candidates, hashLine: hash)
        XCTAssertTrue(result.contains("test"))
        XCTAssertLessThan(result.count, candidates.count)
        var checks = 0
        XCTAssertThrowsError(try gpu.filter(candidates: ["test"], hashLine: hash, isCancelled: { checks += 1; return checks >= 5 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(checks, 5)
        XCTAssertTrue(try gpu.filter(candidates: ["test"], hashLine: hash).contains("test"))
    }
    func testRAR3MaximumUTF16LengthAndPassthrough() throws {
        let gpu = try MetalArchiveFilter()
        // Independent Python SHA1/OpenSSL vector: 52-byte UTF16 password +
        // 8-byte salt + 3-byte counter = 63 bytes, crossing SHA1 block edges.
        let hash = "$RAR3$*0*0001020304050607*2e8b5a2b3ff321e13f92e5c53f8bb363"
        let password = String(repeating: "a", count: 26), long = String(repeating: "a", count: 27)
        XCTAssertEqual(try gpu.filter(candidates: ["wrong", password, long], hashLine: hash), [password, long])
    }
    func testUnsupportedVariantsAndCancellation() throws {
        let gpu = try MetalArchiveFilter()
        let rar = "$rar5$16$000102030405060708090a0b0c0d0e0f$0$00000000000000000000000000000000$8$e9d4686b3b6a9d1e"
        let hashes = [rar.replacingOccurrences(of: "$0$", with: "$25$"), rar.replacingOccurrences(of: "$16$", with: "$15$"), rar + "\n" + rar,
                      "$7z$0$19$1$00$16$" + String(repeating: "00", count: 16), "$RAR3$*0*abc", "$pdf$5*6*256", "name$rar5$16$invalid"]
        for hash in hashes {
            XCTAssertFalse(MetalArchiveFilter.supports(hashLine: hash))
            XCTAssertEqual(try gpu.filter(candidates: ["a", "b"], hashLine: hash), ["a", "b"])
        }
        let long = String(repeating: "a", count: 33)
        XCTAssertEqual(try gpu.filter(candidates: [long, "a\0b"], hashLine: rar), [long, "a\0b"])
        let classic = "$pkzip$1*2*1*0*8*c*1234*000000000000000000000000*$/pkzip$"
        let classicLong = String(repeating: "a", count: 64)
        XCTAssertEqual(try gpu.filter(candidates: [classicLong], hashLine: classic), [classicLong])
        XCTAssertThrowsError(try gpu.filter(candidates: ["password"], hashLine: rar, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
}
