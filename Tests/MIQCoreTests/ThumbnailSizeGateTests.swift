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

    @Test func unknownSizeNeverDeclines() {
        for kind in MIQFileKind.allCases {
            #expect(!kind.declinesThumbnail(fileSizeBytes: nil, isLocal: false, thresholdBytes: Self.threshold))
        }
    }
}
