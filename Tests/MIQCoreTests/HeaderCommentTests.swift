import Foundation
import Testing
@testable import MIQCore

/// The header's free-text description (`MIQHeader.comment`) and its metadata row.
struct HeaderCommentTests {
    private static func commentRow(_ header: MIQHeader) -> String? {
        MIQMetadata(header: header).asDisplayLines().first { $0.field == .comment }?.value
    }

    @Test
    func nifti1DescripIsReadUpToItsFirstNul() throws {
        var data = TestMIQFactory.makeNii(width: 2, height: 2, depth: 2, datatype: .uint8)
        let descrip = Array("TE=30;Time=101112.500".utf8) + [0, 0x41, 0x42]
        data.replaceSubrange(148..<148 + descrip.count, with: descrip)
        let header = try MIQParser().parseNifti(data).header
        #expect(header.comment == "TE=30;Time=101112.500")
        #expect(Self.commentRow(header) == "TE=30;Time=101112.500")
    }

    @Test
    func nifti2DescripIsRead() throws {
        var data = TestMIQFactory.makeNii2(width: 2, height: 2, depth: 2, datatype: .uint8)
        data.replaceSubrange(240..<243, with: Array("FSL".utf8))
        #expect(try MIQParser().parseNifti(data).header.comment == "FSL")
    }

    @Test
    func emptyDescripHasNoRow() throws {
        let header = try MIQParser().parseNifti(
            TestMIQFactory.makeNii(width: 2, height: 2, depth: 2, datatype: .uint8)
        ).header
        #expect(header.comment == nil)
        #expect(Self.commentRow(header) == nil)
    }

    @Test
    func mifCollectsEveryCommentsLine() throws {
        var offset = 0
        var text = ""
        while true {
            text = """
            mrtrix image
            dim: 2,2,2
            vox: 1,1,1
            layout: +0,+1,+2
            datatype: UInt8
            comments: DOE^JOHN [12345]
            comments:   
            comments: DOB: 01/02/1970
            file: . \(offset)
            END

            """
            let next = text.utf8.count
            if next == offset { break }
            offset = next
        }
        let header = try MIQParser().parseMif(Data(text.utf8) + Data(count: 8)).header
        #expect(header.comment == "DOE^JOHN [12345]\nDOB: 01/02/1970")
        #expect(Self.commentRow(header) == "DOE^JOHN [12345]\u{2028}DOB: 01/02/1970")
    }

    @Test
    func nrrdContentIsRead() throws {
        let data = TestMIQFactory.makeNrrd(width: 2, height: 2, depth: 2, datatype: .uint8)
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "NRRD0004\n", with: "NRRD0004\ncontent: T1 MPRAGE\n")
        let header = try MIQParser().parseNrrd(Data(text.utf8)).header
        #expect(header.comment == "T1 MPRAGE")
    }

    @Test
    func metaImageCommentIsRead() throws {
        let data = try TestMIQFactory.makeMetaImage(
            sizes: [2, 2, 2], datatype: .uint8, extraFields: ["Comment = resampled"]
        )
        #expect(try MIQParser().parseMetaImage(data).header.comment == "resampled")
    }

    @Test
    func controlCharactersBecomeSpaces() {
        #expect(MIQParser.headerComment(["a\tb\u{7}c  "]) == "a b c")
        #expect(MIQParser.headerComment(["", "  "]) == nil)
    }

    @Test
    func extraCommentLinesCollapseIntoAnEllipsisLine() {
        let sep = "\u{2028}"
        let lines = (1...10).map { "line \($0)" }
        #expect(MIQMetadata.displayComment(lines.joined(separator: "\n"))
            == ["line 1", "line 2", "line 3", "\u{2026}"].joined(separator: sep))
        // Exactly three lines fit and are shown unchanged; long lines are left to
        // the panel, which cuts by wrapped lines at its width.
        let long = String(repeating: "x", count: 500)
        #expect(MIQMetadata.displayComment("a\nb\n" + long) == ["a", "b", long].joined(separator: sep))
    }
}
