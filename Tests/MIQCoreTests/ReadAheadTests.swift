import Foundation
import Testing
@testable import MIQCore

/// `ReadAhead`'s ranges are the one way the hint can cost performance: advising
/// bytes the preview never touches turns a volume-0 read into a whole-file read.
/// The hint's speed-up itself needs a cold page cache and is measured on demand,
/// not here.
struct ReadAheadTests {
    @Test func threeDimensionalNiftiAdvisesTheWholePayload() throws {
        let file = TestMIQFactory.makeNii(width: 6, height: 5, depth: 4, datatype: .int16)
        let image = try MIQParser().parseNifti(file)
        let range = try #require(ReadAhead.volumeZeroRange(of: image, fileData: file))
        #expect(range == image.payloadOffset..<file.count)
    }

    @Test func fourDimensionalNiftiAdvisesOnlyVolumeZero() throws {
        let file = TestMIQFactory.makeNii(width: 6, height: 5, depth: 4, datatype: .float32, volumes: 10)
        let image = try MIQParser().parseNifti(file)
        let range = try #require(ReadAhead.volumeZeroRange(of: image, fileData: file))
        #expect(range == image.payloadOffset..<(image.payloadOffset + 6 * 5 * 4 * 4))
        #expect(range.upperBound < file.count)
    }

    @Test func volumeInterleavedLayoutAdvisesThroughTheLastVoxelOfVolumeZero() throws {
        // MRtrix's usual 4D layout: time is the fastest axis.
        let (width, height, depth, volumes) = (4, 3, 2, 5)
        let image = Self.stridedImage(
            dimensions: [width, height, depth, volumes],
            strides: [volumes, volumes * width, volumes * width * height, 1]
        )
        let range = try #require(ReadAhead.volumeZeroRange(of: image, fileData: image.storage))
        let lastElement = (width - 1) * volumes + (height - 1) * volumes * width + (depth - 1) * volumes * width * height
        #expect(range == image.payloadOffset..<(image.payloadOffset + (lastElement + 1) * 4))
    }

    @Test func volumeOutermostLayoutAdvisesOnlyVolumeZero() throws {
        let (width, height, depth, volumes) = (4, 3, 2, 5)
        let image = Self.stridedImage(
            dimensions: [width, height, depth, volumes],
            strides: [1, width, width * height, width * height * depth]
        )
        let range = try #require(ReadAhead.volumeZeroRange(of: image, fileData: image.storage))
        #expect(range.count == width * height * depth * 4)
    }

    @Test func truncatedFileNeverAdvisesPastItsEnd() throws {
        let image = Self.stridedImage(dimensions: [4, 3, 2, 1], strides: [1, 4, 12, 24], payloadBytes: 10)
        let range = try #require(ReadAhead.volumeZeroRange(of: image, fileData: image.storage))
        #expect(range.upperBound == image.storage.count)
    }

    @Test func payloadDecodedIntoAFreshBufferIsNotAdvised() throws {
        // A MIF `bit` payload is unpacked at parse time: its offsets aren't file offsets.
        let file = TestMIQFactory.makeMifBit(width: 8, height: 4, depth: 2) { x, _, _ in x.isMultiple(of: 2) }
        let image = try MIQParser().parseMif(file)
        #expect(ReadAhead.volumeZeroRange(of: image, fileData: file) == nil)
    }

    @Test func compressedFilesReadAheadOnlyWhenTheWholeStreamIsInflated() {
        // `.mgz`, `.mif.gz`, the 4D expansion: no budget, the whole stream.
        #expect(ReadAhead.readsAheadCompressed(fileSize: 1_000, volumeZeroBudget: nil, isizeHint: 50_000))
        // 3D `.nii.gz`: the volume-0 budget is the whole payload.
        #expect(ReadAhead.readsAheadCompressed(fileSize: 1_000, volumeZeroBudget: 50_000, isizeHint: 50_000))
        // 4D `.nii.gz`: only a prefix is inflated, so nothing is advised.
        #expect(!ReadAhead.readsAheadCompressed(fileSize: 1_000, volumeZeroBudget: 5_000, isizeHint: 50_000))
        #expect(!ReadAhead.readsAheadCompressed(fileSize: 1_000, volumeZeroBudget: 5_000, isizeHint: nil))
        #expect(!ReadAhead.readsAheadCompressed(fileSize: 0, volumeZeroBudget: nil, isizeHint: nil))
    }

    @Test func largeRangesAreSplitForTheInt32Length() {
        let chunk = ReadAhead.maxAdviseChunk
        #expect(ReadAhead.chunks(of: 10..<20) == [10..<20])
        #expect(ReadAhead.chunks(of: 0..<(2 * chunk + 5)) == [0..<chunk, chunk..<(2 * chunk), (2 * chunk)..<(2 * chunk + 5)])
        #expect(ReadAhead.chunks(of: 7..<7).isEmpty)
        #expect(chunk <= Int(Int32.max))
    }

    /// Progress arrives once per output window; a lead shorter than the input one
    /// window can consume lets inflate fault past the advised range every window.
    @Test func rollingLeadCoversOneInflateWindow() {
        #expect(ReadAhead.Rolling.lead >= MIQBinaryReader.inflateOutputWindow)
    }

    @Test func rollingReadAheadStaysWithinItsLeadOfTheDecompressor() {
        let step = ReadAhead.Rolling.step
        let lead = ReadAhead.Rolling.lead
        let fileSize = 10 * step + 123
        // Start: the first `lead` bytes.
        #expect(ReadAhead.Rolling.nextRange(consumed: 0, advisedUpTo: 0, fileSize: fileSize) == 0..<lead)
        // Nothing more until the lead runs short, then one step.
        #expect(ReadAhead.Rolling.nextRange(consumed: 0, advisedUpTo: lead, fileSize: fileSize) == nil)
        #expect(ReadAhead.Rolling.nextRange(consumed: 1, advisedUpTo: lead, fileSize: fileSize) == lead..<(lead + step))
        // Clipped to the file; nothing past its end.
        #expect(ReadAhead.Rolling.nextRange(consumed: 9 * step, advisedUpTo: 10 * step, fileSize: fileSize) == (10 * step)..<fileSize)
        #expect(ReadAhead.Rolling.nextRange(consumed: fileSize, advisedUpTo: fileSize, fileSize: fileSize) == nil)
        // Simulated inflate: the advised front never falls behind `consumed + lead`
        // nor runs more than `lead + step` ahead.
        var advisedUpTo = 0
        for consumed in stride(from: 0, through: fileSize, by: 13 << 20) {
            if let range = ReadAhead.Rolling.nextRange(consumed: consumed, advisedUpTo: advisedUpTo, fileSize: fileSize) {
                #expect(range.lowerBound == advisedUpTo)
                advisedUpTo = range.upperBound
            }
            #expect(advisedUpTo >= Swift.min(consumed + lead, fileSize))
            #expect(advisedUpTo - consumed <= lead + step)
        }
    }

    @Test func gunzipReportsMonotonicInputProgressWithoutChangingOutput() throws {
        let raw = TestMIQFactory.makeNii(width: 64, height: 64, depth: 32, datatype: .float32, volumes: 3)
        let gz = try TestZlib.gzip(raw)
        var reported: [Int] = []
        let full = try MIQBinaryReader.gunzip(gz, onInputProgress: { reported.append($0) })
        #expect(full == raw)
        #expect(reported.first == 0)
        #expect(reported == reported.sorted())
        #expect((reported.last ?? .max) <= gz.count)

        reported = []
        let prefix = try MIQBinaryReader.gunzip(gz, maxOutputBytes: raw.count / 3, onInputProgress: { reported.append($0) })
        #expect(prefix == raw.prefix(raw.count / 3))
        #expect(reported == reported.sorted())
    }

    @Test func parsingWithReadAheadMatchesParsingWithout() throws {
        let files: [(String, Data)] = [
            (".nii", TestMIQFactory.makeNii(width: 6, height: 5, depth: 4, datatype: .int16, volumes: 3)),
            (".mif", TestMIQFactory.makeMif(width: 6, height: 5, depth: 4, datatype: .float32, layout: [2, 0, 1])),
            (".nii.gz", try TestZlib.gzip(TestMIQFactory.makeNii(width: 6, height: 5, depth: 4, datatype: .uint8, volumes: 3))),
            (".mgz", try TestZlib.gzip(TestMIQFactory.makeMgh(width: 6, height: 5, depth: 4, frames: 1, datatype: .float32))),
        ]
        for (suffix, bytes) in files {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("miq-readahead-\(UUID().uuidString)\(suffix)")
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let plain = try MIQParser().parse(url: url)
            let advised = try MIQParser(readsAhead: true).parse(url: url)
            #expect(plain.storage == advised.storage, "\(suffix)")
            #expect(plain.payloadOffset == advised.payloadOffset, "\(suffix)")
        }
    }

    private static func stridedImage(dimensions: [Int], strides: [Int], payloadBytes: Int? = nil) -> MIQImage {
        let offset = 64
        let elements = dimensions.reduce(1, *)
        let header = MIQHeader(
            littleEndian: true, dimensions: dimensions, pixdim: [1, 1, 1, 1], datatype: .float32,
            voxOffset: offset, sclSlope: 0, sclInter: 0, qformCode: 0, sformCode: 0,
            srowX: [1, 0, 0, 0], srowY: [0, 1, 0, 0], srowZ: [0, 0, 1, 0]
        )
        let storage = Data(count: offset + (payloadBytes ?? elements * 4))
        return MIQImage(header: header, storage: storage, payloadOffset: offset, payloadElementStrides: strides)
    }
}
