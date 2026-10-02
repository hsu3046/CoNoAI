// CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
// 모두 합성 입력이며 고정 암호 벡터는 CoNo 구현과 독립된 LDDC 원본으로 생성했다.
// Oracle: chenmozhijin/LDDC @ 84631e8cd011fcc3f71ca0ae017e2c9758958ffc
// LDDC/core/decryptor/tripledes.py (GPL-3.0-only, Copyright (C) 2024-2025 沉默の金).
// 의존 캐시 decorator만 제거하고 원본 함수를 /tmp에서 실행했다. 실제 가사는 포함하지 않는다.

import Foundation
import Testing

struct QRCLyricsTests {
    @Test(arguments: QRCVectors.blocks.indices)
    func matchesIndependentCipherVectors(_ index: Int) throws {
        let vector = QRCVectors.blocks[index]
        #expect(try QRCBlockCipher.decrypt(bytes(vector.ciphertext)) == bytes(vector.plaintext))
    }

    @Test(arguments: [false, true])
    func decodesCloudAndLocalIndependentVectors(_ local: Bool) throws {
        let data = local ? Data(bytes(QRCVectors.localHex)) : Data(QRCVectors.cloudHex.utf8)
        let lyrics = LRCParser.parse(try QRCLyrics.enhancedLRC(from: data))
        #expect(lyrics.lines.count == 2)
        let line = try #require(lyrics.lines.first)
        #expect(line.text == "하늘 👩🏽‍🚀 が & café (둘) <3")
        #expect(line.start == 0.75)
        #expect(line.explicitEnd == 3.25)
        #expect(line.segments == [
            LyricSegment(characterStart: 0, characterCount: 2, start: 0.75, end: 1.25),
            LyricSegment(characterStart: 3, characterCount: 1, start: 1.55, end: 2.25),
            LyricSegment(characterStart: 5, characterCount: "が & café (둘) <3".count, start: 2.45, end: 3.05)
        ])
        #expect(line.highlightedCharacters(at: 1.4, lineEnd: 3.25) == 2)
        #expect(lyrics.lineIndex(at: 3.3) == nil)
        #expect(lyrics.lines[1].text == "별")
        #expect(lyrics.lines[1].start == 3.75)
    }

    @Test func handlesLocalMaskBoundaryFromOriginalCAlgorithm() {
        let result = QRCLocalMask.transform([UInt8](repeating: 0, count: 32_780))
        #expect(Array(result[32_760..<32_780]) == bytes(QRCVectors.maskBoundaryHex))
    }

    @Test func acceptsUppercaseHexWhitespaceAndBOM() throws {
        let text = "\u{FEFF} \n" + QRCVectors.cloudHex.uppercased() + "\r\n\t"
        #expect(try QRCLyrics.enhancedLRC(from: Data(text.utf8)) == QRCLyrics.enhancedLRC(from: Data(QRCVectors.cloudHex.utf8)))
    }

    @Test func preservesLiteralXMLLineBreaksAndEntities() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <QrcInfos><!-- ' comments keep quotes' --><LyricInfo LyricCount="1"><Lyric_1 LyricContent="[0,1000]A &quot;B&quot; &apos;C&apos;(0,1000)
        [1000,1000]둘(1000,1000)
        " LyricType="1"/></LyricInfo></QrcInfos>
        """
        let lyrics = LRCParser.parse(try QRCLyrics.enhancedLRC(from: Data(xml.replacingOccurrences(of: "\n", with: "\r\n").utf8)))
        #expect(lyrics.lines.map { $0.text } == ["A \"B\" 'C'", "둘"])
        #expect(lyrics.lines[1].start == 1)
    }

    @Test func preservesLineOnlyLyricsAndLongEnds() throws {
        let text = "[0,1000]\n[1000,15000]합성 긴 음\n[17000,1000]한 단어(17000,1000)"
        let lyrics = LRCParser.parse(try QRCLyrics.enhancedLRC(from: Data(text.utf8)))
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lines[1].segments.isEmpty)
        #expect(lyrics.end(of: 1) == 16)
        #expect(lyrics.lineIndex(at: 15.9) == 1)
        #expect(lyrics.lines[2].segments.first?.start == 17)
    }

    @Test(arguments: ["", "012", "0x0123", "00zz", "QRC unsupported"])
    func rejectsInvalidHexOrUnsupportedFiles(_ text: String) {
        #expect(throws: QRCLyrics.DecodeError.invalidFormat) { try QRCLyrics.enhancedLRC(from: Data(text.utf8)) }
    }

    @Test(arguments: ["00", "00010203040506", "9825b0ace3028368e8fc6c"])
    func rejectsIncompleteBlocks(_ hex: String) {
        let data = hex.hasPrefix("9825") ? Data(bytes(hex)) : Data(hex.utf8)
        #expect(throws: QRCLyrics.DecodeError.invalidCiphertext) { try QRCLyrics.enhancedLRC(from: data) }
    }

    @Test func rejectsCorruptionAndExtraCipherBlocks() {
        let extra = QRCVectors.cloudHex + "a27b02aa779bf226" // upstream encryption of eight zero bytes
        #expect(throws: QRCLyrics.DecodeError.invalidCompression) { try QRCLyrics.enhancedLRC(from: Data(extra.utf8)) }
        var corrupt = bytes(QRCVectors.localHex)
        corrupt[11] ^= 0x40
        #expect(throws: QRCLyrics.DecodeError.invalidCompression) { try QRCLyrics.enhancedLRC(from: Data(corrupt)) }
    }

    @Test func rejectsEncryptedInvalidUTF8() {
        #expect(throws: QRCLyrics.DecodeError.invalidUTF8) { try QRCLyrics.enhancedLRC(from: Data(QRCVectors.invalidUTF8Hex.utf8)) }
    }

    @Test func boundsFileAndExpandedSize() {
        #expect(throws: QRCLyrics.DecodeError.fileTooLarge) { try QRCLyrics.enhancedLRC(from: Data(repeating: 0, count: QRCLyrics.maximumFileBytes + 1)) }
        #expect(throws: QRCLyrics.DecodeError.expandedTooLarge) { try QRCLyrics.enhancedLRC(from: Data(QRCVectors.expandedBombHex.utf8)) }
    }

    @Test(arguments: [
        "<QrcInfos><Lyric_1 LyricType=\"1\" LyricContent=\"[0,1]별(0,1)\"></QrcInfos>",
        "<!DOCTYPE QrcInfos SYSTEM 'file:///tmp/never-read'><QrcInfos/>",
        "<!DOCTYPE QrcInfos [<!ENTITY x 'value'>]><QrcInfos/>",
        "<QrcInfos><Lyric_1 LyricType=\"2\" LyricContent=\"[0,1]별(0,1)\"/></QrcInfos>",
        "<QrcInfos><Lyric_1 LyricType=\"1\" LyricContent=\"[0,1]별(0,1)\"/><Lyric_1 LyricType=\"1\" LyricContent=\"duplicate\"/></QrcInfos>"
    ])
    func rejectsMalformedOrUnsafeXML(_ text: String) {
        #expect(throws: QRCLyrics.DecodeError.invalidXML) { try QRCLyrics.enhancedLRC(from: Data(text.utf8)) }
    }

    @Test func boundsXMLDepth() {
        let text = String(repeating: "<a>", count: 33) + String(repeating: "</a>", count: 33)
        #expect(throws: QRCLyrics.DecodeError.invalidXML) { try QRCLyrics.enhancedLRC(from: Data(text.utf8)) }
    }

    @Test(arguments: [
        "[-1,1000]별(0,1000)", "[86400000,1]별(86400000,1)",
        "[0,1000]별(0,1001)", "[1000,1000]별(0,1000)",
        "[0,1000]앞(0,600)뒤(500,500)", "[9999999999999999999999,1000]별(0,1000)",
        "[offset:86400001]\n[0,1000]별(0,1000)"
    ])
    func rejectsInvalidAbsoluteTiming(_ text: String) {
        #expect(throws: QRCLyrics.DecodeError.invalidTiming) { try QRCLyrics.enhancedLRC(from: Data(text.utf8)) }
    }

    @Test(arguments: ["[0,1000]별(-1,1000)", "[0,1000]별(0,broken)", "[0,1000]별(0,1000)untimed tail"])
    func rejectsMalformedWordMarkers(_ text: String) {
        #expect(throws: QRCLyrics.DecodeError.invalidStructure) { try QRCLyrics.enhancedLRC(from: Data(text.utf8)) }
    }

    @Test(arguments: ["<00:05>", "< 00:05 >", "<outer<00:05>>"])
    func rejectsTextThatLRCWouldConsume(_ text: String) {
        let qrc = "[0,1000]합성 \(text)(0,1000)"
        #expect(throws: QRCLyrics.DecodeError.ambiguousText) { try QRCLyrics.enhancedLRC(from: Data(qrc.utf8)) }
    }

    @Test(arguments: ["[후렴] 합성", "[offset:500] 합성", "[00:05] 합성"])
    func preservesLeadingTagsInLineOnlyAndTimedText(_ text: String) throws {
        for content in ["[1000,1000]\(text)", "[1000,1000]\(text)(1000,1000)"] {
            let lyrics = LRCParser.parse(try QRCLyrics.enhancedLRC(from: Data(content.utf8)))
            #expect(lyrics.lines.count == 1)
            #expect(lyrics.lines.first?.start == 1)
            #expect(lyrics.lines.first?.text == text)
        }
    }

    @Test func boundsLineLengthAndCounts() {
        let longLine = "[0,1]" + String(repeating: "x", count: 65_536)
        #expect(throws: QRCLyrics.DecodeError.tooComplex) { try QRCLyrics.enhancedLRC(from: Data(longLine.utf8)) }
        let manyLines = Array(repeating: "[0,1]x(0,1)", count: 10_001).joined(separator: "\n")
        #expect(throws: QRCLyrics.DecodeError.tooComplex) { try QRCLyrics.enhancedLRC(from: Data(manyLines.utf8)) }
        let manyWords = Array(repeating: "[0,0]" + String(repeating: "x(0,0)", count: 1_000), count: 51).joined(separator: "\n")
        #expect(throws: QRCLyrics.DecodeError.tooComplex) { try QRCLyrics.enhancedLRC(from: Data(manyWords.utf8)) }
    }

    @Test(arguments: ["[ti:합성 제목]", "[0,1000]", "[0,1000](0,1000)"])
    func rejectsEmptyLyrics(_ text: String) {
        #expect(throws: QRCLyrics.DecodeError.noLyrics) { try QRCLyrics.enhancedLRC(from: Data(text.utf8)) }
    }

    private func bytes(_ hex: String) -> [UInt8] {
        let characters = Array(hex.filter { !$0.isWhitespace })
        return stride(from: 0, to: characters.count, by: 2).map { UInt8(String(characters[$0...$0 + 1]), radix: 16)! }
    }
}

struct QRCBlockVector: Sendable { let plaintext: String; let ciphertext: String }

enum QRCVectors {
    static let blocks = [
        QRCBlockVector(plaintext: "0000000000000000", ciphertext: "a27b02aa779bf226"),
        QRCBlockVector(plaintext: "ffffffffffffffff", ciphertext: "4b789c44381642a3"),
        QRCBlockVector(plaintext: "0001020304050607", ciphertext: "ce92cac4ea3c8406"),
        QRCBlockVector(plaintext: "0123456789abcdef", ciphertext: "6c6467a1fc44c95b"),
        QRCBlockVector(plaintext: "436f4e6f51524321", ciphertext: "0423227aa2e9889c"),
        QRCBlockVector(plaintext: "0e02ad49fe9336c6981a09f3c03f411d73fb49769baeaa12815e13a3e7b810612ba5949aea6e40a0cf4b9d659f7f5d3d13285ad9049d0f737a2eff15d2fc7da9d7842f5708a61973ff67d57d5ee3fb358508d725425f2bc8fb661c7ca9b479675ea59147a14a2ffd0caf6a05a20f6cee7518299c74473203c3e570c9fffd70bf0439cabaf8f4b056d6bd8a1feac69ddf54c18fe1df1f3f1acb6da8323f7072223941fb39a89d6c25458ec419a6088d768a4649f9458ae51541f1996a910254a45fb25c551b6d0e6605b8a18d86a78d3807afa211172dd73452f6687bd53b543c0613096120455b6dbf306af777f9f3b7e9b872a44c78a388ccf33584c7258cb526259e12491d94c4c9aaae5954ef8ea5ccd35cb149cc777525c60a35c0a68ff7a52fa5e2c52a9296b243e5753abd207402c347c8a490eaae66dc86a3aa88f5f32633f37bd217a57234cbadc84490895ecd3c2c82a398227fc32155004d723ebf9b58df805fa47991f89245db09d24a0eee40e9641769c0e8f0d6161a7a916ae8647cc88efdd8df7cf3b24b73a5a249e43caa3f3aebb9c49a39c1e7adbdab3c1494528285debda093efd7267467498876a674a8d050ba92c3bc2946185281f26a4648980e5e66677ebf116d3374c45f50218b4421f04ed991789c11772eb7710ef91bd1c305bb154f69aa2a94b0c58a648b776c4d6f4f14964fe7cd7ff6d0c77a67619c1d0b9df5ace491e1f5f188af77dc69fc26d8912fc58ea950b3b966f86474401a01bc4394afdfd16c9fd8740fcd71fab91990378ab94189ff2d14bdcadc116b21d58fb18282af165db4125b84f1163ca1a57ba05f227d335c10adc3a85f4a1d1e960954e3370c203c317e9ec1610d0fc2e52774ff869f981c7c9364e40e79a252c6474427c17779613824ed658ee80054301581949613e30df31734b19e0fb9f84acd87506feb5673c2e1823f98abdd487021b1d798b49c1b696caad73bf0bc501eff77ba3de3f6f6fb4b634b0ceef8bb1949d0ac8ea4eeaca3a11fdf5b00cf7ea9340df4c7d3c502ad7666762005116d36c63b1fd778725fdea3c389de3577cb4dc85af6ccf2fb5378577e48773f581fd72b6bc206582e6ad40b1ff202", ciphertext: "e8392710c46a3dd074f6107229586d61e21a2728a8c0a1533cbca3dd446f58556059c7dc7dfa5e4d8985269b71a66af6c5a08b2e2d3eb1b3aeca1a4c8f4a04276063e38b21805c81a1b9acb72192c0e8cf6e9c9f50e7f590fd4b015734539a54ab27e729b69734a0df1ebf23d7fdf897b7e17f6c82f928f764dc8e302a38536cf53ab6ebbaf6a473ea2d2d1c926f9130a3b410ac9a3621cdcf50ea388ae72557d9a814786aece441e4e2f167b74974c50f6da86e1c2b800ac6991e42237fd6fc4438af90a71dc5d147f96904a73a5cbeb2f58985c5b37da9ea6dc93b80f491a7b821e1e8b3befc436e909dd04a2f9e52805afbd417b6237d3ec89253c88016d9b79572c05d2f7421d9400450d180156cc0a7f9dd56531e33058e0b0b9eb59d119a3f1639422d7e170797677be2a152536b1306b4def7a64e91f5f4615fc9274d94890d394075db2ed9b7c986ed246964364e326ee8a62279f22e122f7311a9c66be5d076149bfc875f432a68de9f9046761b558c7b4e33c51e13fab8c8f5f23ac938a0c67ea7bea8be9447b1cc9d21c0f71cbea9b08f611cb24713500c13295fb6416de33bc6ce5b5f830d64e65d4d9527357a078a9c8d7c594dc107adf2c0770b2d4871478c2e805a5ea6c83b1c7c62a82805356ffbe02a29464e9e01e6d0bcab48914722ff1e44308626e2bc8d6da5a025a3b3cc9a7e38902661dd3e9793f3318327f473318edfd5453788d2f4bfaaf37473a0cd7fbcf8191cea344920acb3b7f00aa4fbe8dace2d69e748585175bbc5dbc50daaa315c28d42044dd43359958c75dbd2cc539e3d62e5c84fdce1d77365757becec0d38e83bdffee8baa623f0afdce2de00dd0591c41b9b7b3aa519be2adfc593d1ed68f1dc6139a0f713f3402707d99ded91cae795f55513e6a0a676fba2663e028c337ae01a3396eed00e83a8d67275a4d6c36574c361be43b132d25f75926f59a0edcc14df5a2f3577b582bb58902b22920dcf1510aef92f070d25e40e10f9346de9e2be615b88c940742d5511ca070cd9d21c23d3febdd2fa457ec3fa1d0dfa824bbef0d5e581082ebdb1e1d65186c2c5a2aa7eb5f7cab78f83701fe9af54c898bdf39f256c89100372da"),
    ]
    static let cloudHex = """
    5693663152109dd1b64ed2680459f13881aa15d10db4cc8324b86311d0d741bd6af5d8724f2b75716c3a763afd2e1295
    71af815a2be76f353da7c356aa0d0cfffaaf93ebaae303d09d2a9cea52476fed47d80b815f418c78e80e919d095c51db
    723a2a148cdf1dba554d0e5411ef6b4a77d9e2b6608843c08c1e7482657d551cb38b4b40f58f9c6b2f1ac9ec529fcfab
    407d2a70aaca8c6ded789464542cb2fed4c561be82de3d67db6e778579fe96bfc2432a4fc25d5cc35240e6f5aac38f55
    c63783140845b5a02441caf0fec06b597da5d8b5ce29a4113273adb424e5a2859f2e10f1c0557adac51df16639f9e86a
    """
    static let localHex = """
    9825b0ace3028368e8fc6c340c3d3852d3c34495d1c1797a8163073d3aaea503778bf71928c92e810fb5acee6a06e752
    e8b378b9a58c5c04f6e262d13f208cd8249ce39c3763a15ad5f599003046e26c201e4543b518fba69f3ed2ed4836f518
    82820c539e2da29b842fca61a50981d21c1db30ed26c32b03739bd104928602a4b0916468e137537a5f47ad1141049f5
    4cc2fe0c85dafd2c475d94fced9104a409cb19d0e83e5b05f446ef505abf2b9f1dfb6e0ef18de38026664862d38b9931
    9eaf15f3d046025a1b76333ca8561dce86a835fade4ee10a183a66d735e5c189eaaa6589e3118bb63ddc948cb133649e
    967ad39e8293009821ba9d
    """
    static let expandedBombHex = """
    0be6f936754b7fc0523234bf9cab558f36b1974196768c2ca27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226
    a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226a27b02aa779bf226db52bf6036cda8d9
    """
    static let invalidUTF8Hex = """
    17041dd542aa2084bb0b5a9abda36903
    """
    static let maskBoundaryHex = """
    d852f76790cad64a4ad6ca9067f752d8a166629f
    """
}
