import Foundation
import Testing
@testable import MIQCore

/// `MIQFileKind.declinesThumbnail` keeps Finder from fully decompressing one
/// large file per icon, without costing thumbnails that are cheap to render.
struct ThumbnailSizeGateTests {
    private static let threshold = 100

    @Test func boundedNiftiNeverDeclines() {
        for kind in [MIQFileKind.nii, .niiGz] {
            for isLocal in [true, false] {
                #expect(!kind.declinesThumbnail(fileSizeBytes: 1_000, isLocal: isLocal, thresholdBytes: Self.threshold))
            }
        }
    }

    @Test func largeFullReadKindsDecline() {
        for kind in [MIQFileKind.mgz, .mifGz, .nrrd] {
            #expect(kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: true, thresholdBytes: Self.threshold))
            #expect(kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    @Test func atOrBelowThresholdRenders() {
        for kind in MIQFileKind.allCases {
            #expect(!kind.declinesThumbnail(fileSizeBytes: Self.threshold, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    @Test func largeUncompressedMghMifDeclineOnlyOnNetwork() {
        for kind in [MIQFileKind.mgh, .mif] {
            // Memory-mapped locally: only the centre slice's pages are read.
            #expect(!kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: true, thresholdBytes: Self.threshold))
            #expect(kind.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: false, thresholdBytes: Self.threshold))
        }
    }

    @Test func largeRawNrrdDeclinesOnlyOnNetwork() {
        // Confirmed raw from its header: memory-mapped locally, like MIF.
        #expect(!MIQFileKind.nrrd.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: true,
                                                    thresholdBytes: Self.threshold, hasRawPayload: true))
        #expect(MIQFileKind.nrrd.declinesThumbnail(fileSizeBytes: Self.threshold + 1, isLocal: false,
                                                   thresholdBytes: Self.threshold, hasRawPayload: true))
    }

    @Test func nrrdHeaderProbeReadsEncoding() {
        func header(_ fields: [String]) -> Data {
            Data((["NRRD0004", "type: uint8", "dimension: 3", "sizes: 4 4 1"] + fields)
                .joined(separator: "\n").utf8) + Data("\n\n".utf8) + Data(repeating: 0, count: 16)
        }
        #expect(MIQParser.nrrdHasRawPayload(prefix: header(["encoding: raw"])))
        #expect(MIQParser.nrrdHasRawPayload(prefix: header([])))                    // raw is the default
        #expect(!MIQParser.nrrdHasRawPayload(prefix: header(["encoding: gzip"])))
        #expect(!MIQParser.nrrdHasRawPayload(prefix: header(["encoding: raw", "data file: x.raw"])))
        #expect(!MIQParser.nrrdHasRawPayload(prefix: Data("NRRD0004\nencoding: raw\n".utf8)))  // no blank line within the probe
        #expect(!MIQParser.nrrdHasRawPayload(prefix: Data("not nrrd\n\n".utf8)))
    }

    @Test func unknownSizeNeverDeclines() {
        for kind in MIQFileKind.allCases {
            #expect(!kind.declinesThumbnail(fileSizeBytes: nil, isLocal: false, thresholdBytes: Self.threshold))
        }
    }
}
