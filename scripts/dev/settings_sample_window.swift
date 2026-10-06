// Computes the intensity-window table that ships next to a Settings sample.
//
// Run by scripts/dev/make_settings_sample.py (which builds it as a throwaway
// SwiftPM package against this repository's MIQCore); not part of any target.
//
// A sample is a single slice, but the Quick Look preview derives its window
// from all three centre planes of the *full* volume. So for every setting the
// Settings window can hold — lower 0…49, upper 51…100, each orientation mode —
// this records the exact bounds MIQCore's cold path (`centerPreview`) computes
// on the full volume, and Settings renders the slice with those bounds.

import Foundation
import MIQCore

struct WindowTable: Codable {
    /// Per `ViewOrientation.rawValue`: `lower[p]` is the low bound at lower
    /// percentile p (0…49), `upper[p - 51]` the high bound at upper percentile p.
    var modes: [String: Bounds] = [:]

    struct Bounds: Codable {
        var lower: [Float]
        var upper: [Float]
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: settings_sample_window INPUT_VOLUME OUTPUT.window.json\n".utf8))
    exit(2)
}

let volume = MIQVolume(image: try MIQParser().parse(url: URL(fileURLWithPath: arguments[1])))
var table = WindowTable()

for mode in ViewOrientation.allCases {
    var bounds = WindowTable.Bounds(lower: Array(repeating: 0, count: 50), upper: Array(repeating: 0, count: 50))
    // Lower percentile k pairs with upper 100 - k, so 50 renders cover both
    // ranges. Colouring is off: a label map's window only matters when it is.
    for k in 0...49 {
        let options = RenderingOptions(lowerPercentile: Double(k), upperPercentile: Double(100 - k),
                                       orientation: mode, segmentationColoring: .off)
        guard let window = volume.centerPreview(maxDimension: 64, options: options).windowBounds else {
            FileHandle.standardError.write(Data("No intensity window (no finite voxels?)\n".utf8))
            exit(1)
        }
        bounds.lower[k] = window.low
        bounds.upper[49 - k] = window.high
    }
    table.modes[mode.rawValue] = bounds
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(table).write(to: URL(fileURLWithPath: arguments[2]))
print("Wrote window table to \(arguments[2])")
