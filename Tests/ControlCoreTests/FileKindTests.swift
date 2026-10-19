import Foundation
import Testing
@testable import ControlCore

@Suite("File kind / names / size labels (B13)")
struct FileKindTests {
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 12)
    static let mp4: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D] + [0, 0, 0, 0]
    static let mov: [UInt8] = [0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20] + [0, 0, 0, 0]
    static let heic: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63] + [0, 0, 0, 0]
    static let pdf: [UInt8] = Array("%PDF-1.4 rest of head".utf8.prefix(16))
    static let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 12)
    static let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: 0, count: 8)

    @Test func extensionTableAndSignatures() {
        #expect(FileKind.info(forFileName: "a.PNG") == FileKind.Info(kind: "image", contentType: "image/png", ext: "png"))
        #expect(FileKind.info(forFileName: "report.docx")?.contentType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(FileKind.info(forFileName: "clip.mp4")?.kind == "video" && FileKind.info(forFileName: "x.exe") == nil && FileKind.info(forFileName: "noext") == nil)
        #expect(FileKind.signature(of: Self.png) == "png" && FileKind.signature(of: Self.jpeg) == "jpeg" && FileKind.signature(of: Self.mp4) == "mp4")
        #expect(FileKind.signature(of: Self.mov) == "mov" && FileKind.signature(of: Self.pdf) == "pdf" && FileKind.signature(of: Self.zip) == "zip" && FileKind.signature(of: Self.ole) == "ole")
        #expect(FileKind.signature(of: Self.heic) == "heic")
        #expect(FileKind.info(forFileName: "picture.heic") == nil)
        #expect(FileKind.info(forFileName: "picture.heic", allowHEICPreview: true)?.kind == "image")
        #expect(FileKind.signature(of: [1, 2, 3]) == nil)
    }

    @Test func headMustAgreeWithTheExtension() {
        #expect(FileKind.rejection(fileName: "a.png", head: Self.png) == nil)
        #expect(FileKind.rejection(fileName: "a.png", head: Self.jpeg)?.contains("jpeg") == true)
        #expect(FileKind.rejection(fileName: "a.docx", head: Self.zip) == nil && FileKind.rejection(fileName: "a.doc", head: Self.ole) == nil)
        #expect(FileKind.rejection(fileName: "a.doc", head: Self.zip) == nil)     // a .doc that is really OOXML still opens
        #expect(FileKind.rejection(fileName: "a.mov", head: Self.mp4) == nil)     // both are ISO base media
        #expect(FileKind.rejection(fileName: "notes.txt", head: [0x68, 0x69]) == nil)   // text has no signature
        #expect(FileKind.rejection(fileName: "a.exe", head: Self.zip)?.contains("not in the allowlist") == true)
        #expect(FileKind.rejection(fileName: "a.pdf", head: []) != nil)
        #expect(FileKind.rejection(fileName: "a.heic", head: Self.heic) != nil)
        #expect(FileKind.rejection(fileName: "a.heic", head: Self.heic, allowHEICPreview: true) == nil)
        #expect(FileKind.rejection(fileName: "a.heic", head: Self.mp4, allowHEICPreview: true) != nil)
    }

    @Test func namesAreDecodedSanitisedAndCapped() {
        #expect(FileNames.name(from: URL(string: "https://h.example/dir/%E7%94%B5%E5%AD%90%E5%8F%91%E7%A5%A8-17.31.pdf")!) == "电子发票-17.31.pdf")
        #expect(FileNames.sanitize("../../etc:passwd\u{0}.pdf", fallback: "file.pdf") == "etcpasswd.pdf")
        #expect(FileNames.sanitize("   ", fallback: "file.pdf") == "file.pdf")
        let long = String(repeating: "长", count: 200) + ".docx"
        let capped = FileNames.sanitize(long, fallback: "f.docx")
        #expect(capped.count <= 120 && capped.hasSuffix(".docx"))
        #expect(FileNames.name(from: URL(string: "https://h.example/")!) == "file")
    }

    @Test func sizeLabelsParseAndMatchWithinTolerance() {
        // 1.2G: 1.2 * 1_073_741_824 = 1_288_490_188.8, Double.rounded() (round half away from zero on a
        // non-tie value) rounds up -> 1_288_490_189; verified with `swift -e` on 2026-09-22 (brief had ...188).
        #expect(FileSizeLabel.bytes("74K") == 75_776 && FileSizeLabel.bytes("23.5M") == 24_641_536 && FileSizeLabel.bytes("512B") == 512 && FileSizeLabel.bytes("1.2G") == 1_288_490_189)
        #expect(FileSizeLabel.bytes("hello") == nil && FileSizeLabel.bytes("01:14") == nil)
        #expect(FileSizeLabel.matches(size: 75_543, label: "74K") && FileSizeLabel.matches(size: 24_684_024, label: "23.5M") && FileSizeLabel.matches(size: 14_342, label: "14K"))
        #expect(!FileSizeLabel.matches(size: 90_000, label: "74K") && !FileSizeLabel.matches(size: 100, label: "junk"))
    }

    @Test func oversizedSizeLabelsReturnNilInsteadOfTrapping() {
        #expect(FileSizeLabel.bytes("99999999999G") == nil && FileSizeLabel.bytes("9223372036854775807B") != nil)
        #expect(!FileSizeLabel.matches(size: 1, label: "99999999999G"))
    }

    @Test func sanitiseNeverExceedsTheCapEvenWithLongExtensions() {
        let longExt = "a." + String(repeating: "x", count: 119)
        #expect(FileNames.sanitize(longExt, fallback: "f").count <= 120)
        let absurd = String(repeating: "n", count: 130) + "." + String(repeating: "e", count: 200)
        #expect(FileNames.sanitize(absurd, fallback: "f").count == 120)
        let normal = String(repeating: "长", count: 200) + ".docx"
        let capped = FileNames.sanitize(normal, fallback: "f")
        #expect(capped.count == 120 && capped.hasSuffix(".docx"))
    }

    @Test func matchesUsesTheSameParsingAsBytes() {
        #expect(FileSizeLabel.matches(size: 15_136, label: "14K") && FileSizeLabel.matches(size: 15_136, label: " 14K "))
        #expect(FileSizeLabel.bytes(" 14K ") == 14_336)
    }
}
