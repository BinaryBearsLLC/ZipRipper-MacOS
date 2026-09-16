import XCTest
@testable import ZipRipperCore

final class MetalZIPFilterTests: XCTestCase {
    private func hash(_ mode: Int = 3, _ verifier: String = "256b") -> String {
        let salt = (0..<(4 + mode * 4)).map { String(format: "%02x", $0) }.joined()
        return "fixture.zip/file:$zip2$*0*\(mode)*0*\(salt)*\(verifier)*1*00*00000000000000000000*$/zip2$:file:fixture.zip"
    }

    func testIndependentPBKDF2KnownAnswersOnGPU() throws {
        let gpu = try MetalZIPFilter()
        XCTAssertFalse(gpu.deviceName.isEmpty)
        print("Metal ZIP known-answer device: \(gpu.deviceName)")
        // Python hashlib.pbkdf2_hmac('sha1', password.encode('utf-8'),
        // bytes(range(4+mode*4)), 1000, 2*(8+8*mode)+2)[-2:].hex().
        // Full archive authentication is deliberately left to John.
        let passwords = ["password", "", "päss🔑", String(repeating: "a", count: 63), String(repeating: "b", count: 64)]
        let verifiers = [["b51c", "14d5", "1f7f", "03b2", "c40d"],
                         ["c58d", "743d", "43a8", "9a69", "88b7"],
                         ["256b", "3bc9", "8a17", "cc0d", "820e"]]
        for mode in 1...3 {
            for (index, password) in passwords.enumerated() {
                let line = hash(mode, verifiers[mode - 1][index])
                XCTAssertTrue(MetalZIPFilter.supports(hashLine: line))
                XCTAssertEqual(try gpu.filter(candidates: ["wrong", password, "incorrect"], hashLine: line), [password], "AES mode \(mode), vector \(index)")
            }
        }
    }

    func testUnsupportedCandidatesArePreservedInOriginalOrder() throws {
        let gpu = try MetalZIPFilter()
        let long = String(repeating: "x", count: 65)
        let unicodeLong = String(repeating: "🔑", count: 17)
        let null = "pass\0word"
        let candidates = [long, "wrong", "password", unicodeLong, null, "password"]
        XCTAssertEqual(try gpu.filter(candidates: candidates, hashLine: hash()), [long, "password", unicodeLong, null, "password"])
        XCTAssertEqual(try gpu.filter(candidates: [], hashLine: hash()), [])
    }

    func testUnsupportedOrMalformedHashesFallBackWithoutDroppingCandidates() throws {
        let gpu = try MetalZIPFilter()
        let valid = hash()
        let malformed = ["", "$pkzip2$abc", valid + "\n" + valid,
                         valid.replacingOccurrences(of: "*0*3*0*", with: "*0*4*0*"),
                         valid.replacingOccurrences(of: "*0*3*0*", with: "*1*3*0*"),
                         valid.replacingOccurrences(of: "*256b*", with: "*25zz*"),
                         valid.replacingOccurrences(of: "*1*00*", with: "*2*00*"),
                         valid.replacingOccurrences(of: "000102030405060708090a0b0c0d0e0f", with: "00"),
                         valid.replacingOccurrences(of: "*$/zip2$", with: "")]
        for line in malformed {
            XCTAssertFalse(MetalZIPFilter.supports(hashLine: line), line)
            XCTAssertEqual(try gpu.filter(candidates: ["wrong", "password"], hashLine: line), ["wrong", "password"])
        }
    }

    func testNonMultipleOfThreadgroupSize() throws {
        let gpu = try MetalZIPFilter()
        // hashlib independently found no 256b verifier among wrong-0...wrong-4106.
        // Cross both the 4096-candidate batch boundary and SIMD group boundaries.
        var candidates = (0..<4107).map { "wrong-\($0)" }
        candidates[4095] = "password"
        candidates[4096] = "password"
        candidates[4106] = "password"
        let result = try gpu.filter(candidates: candidates, hashLine: hash())
        XCTAssertEqual(result, ["password", "password", "password"])
    }

    func testVerifierCollisionRemainsForFullJohnVerification() throws {
        let gpu = try MetalZIPFilter()
        // Independently derived with Python hashlib, these distinct passwords
        // share verifier 64a4: a survivor cannot be treated as a full recovery.
        XCTAssertEqual(try gpu.filter(candidates: ["wrong-369", "password", "wrong-561"], hashLine: hash(3, "64a4")),
                       ["wrong-369", "wrong-561"])
    }

    func testUTF8ByteBoundary() throws {
        let gpu = try MetalZIPFilter()
        let password = String(repeating: "🔑", count: 16) // Exactly 64 UTF-8 bytes.
        XCTAssertEqual(try gpu.filter(candidates: ["wrong", password], hashLine: hash(3, "e09a")), [password])
    }

    func testReal7ZipAES256ArchiveVerifier() throws {
        // Real 7-Zip 26.03 AES256 ZIP fixture, password ZipRipper42!.
        // Header/salt/ciphertext/authentication extracted independently with
        // Python zipfile + struct; Python hashlib/hmac verified its full MAC.
        let line = "$zip2$*0*3*0*afe4fdaed1d595f2a4bc50fe81cde152*b275*36*093f0ddfe613edb871cac00a24bbd5ddb20ec850effd1f42b923b5a357a35526cd716fa52441a7c4dbf5bf69d8e18811e5069412e75a*fbc7bf9ccd913f301636*$/zip2$"
        let gpu = try MetalZIPFilter()
        XCTAssertTrue(MetalZIPFilter.supports(hashLine: line))
        XCTAssertEqual(try gpu.filter(candidates: ["ZipRipper42", "ZipRipper42!", "ZipRipper43!"], hashLine: line), ["ZipRipper42!"])
    }
}
