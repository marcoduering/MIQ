import Foundation

/// Maps integer segmentation labels to display RGB. Two colour schemes:
/// a deterministic hash-based *random* palette (categorical, distinct per label,
/// stable across every plane/slice/timepoint without a pre-scan), and a curated
/// *FreeSurfer* palette — the canonical colours for the common aseg + aparc
/// (Desikan-Killiany) structures, with any label not in the table falling back
/// to the random palette. Label 0 is background (black). A monochrome-white
/// mode renders every non-zero label white — used for a detected binary mask
/// where a coloured palette adds nothing.
///
/// Port of MIQ-Win's `SegmentationLut.cs`.
public struct SegmentationLut: Sendable {
    enum Kind: Sendable {
        case random
        case freeSurfer
        case monochromeWhite
    }

    let kind: Kind

    /// Returns the display RGB triple for a voxel label. Label 0 is always black.
    func lookup(_ label: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        if label == 0 { return (0, 0, 0) }
        switch kind {
        case .monochromeWhite:
            return (255, 255, 255)
        case .freeSurfer:
            if let packed = Self.freeSurferTable[label] {
                return Self.unpack(packed)
            }
            return Self.randomColor(for: label)
        case .random:
            return Self.randomColor(for: label)
        }
    }

    // MARK: - FreeSurfer detection

    static func isFreeSurferLabel(_ label: Int) -> Bool {
        freeSurferTable[label] != nil
    }

    // A FreeSurfer label that is BOTH distinctive (a naive sequential labelling
    // never reaches it) AND always present in a whole-brain segmentation:
    //   41..54  right-hemisphere core structures;
    //   251..255 corpus callosum;
    //   1000+   cortical parcellation.
    // Optional structures (77/80 hypointensities, 85 optic-chiasm, 58/26
    // accumbens) are deliberately excluded — they may be absent.
    private static func isFreeSurferSignature(_ label: Int) -> Bool {
        (label >= 41 && label <= 54) || (label >= 251 && label <= 255) || label >= 1000
    }

    /// True when the sampled labels look like a FreeSurfer parcellation: >= 3
    /// non-zero labels, a majority are in the canonical table, AND at least one is
    /// a FreeSurfer signature structure. The signature guard prevents a generic
    /// small-integer tissue map (1=CSF / 2=GM / 3=WM) — whose 2 and 3 coincide
    /// with FreeSurfer's white-matter and cortex labels — from being mistaken for
    /// FreeSurfer. Such files fall through to the random palette instead.
    static func looksLikeFreeSurfer(_ labels: Set<Int>) -> Bool {
        var nonZero = 0
        var known = 0
        var hasSignature = false
        for l in labels {
            if l == 0 { continue }
            nonZero += 1
            guard isFreeSurferLabel(l) else { continue }
            known += 1
            if isFreeSurferSignature(l) { hasSignature = true }
        }
        return nonZero >= 3 && known * 2 >= nonZero && hasSignature
    }

    // MARK: - Random palette

    // Deterministic per-label colour: Knuth multiplicative hash spread → HSV
    // with saturation floored well above 0 (never grey or near-white, which is
    // reserved for binary masks). Identical for the same label across all
    // planes/slices/timepoints. No pre-scan needed.
    private static func randomColor(for label: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let h = UInt32(bitPattern: Int32(truncatingIfNeeded: label)) &* 2654435761
        let hue = Float((h >> 8) & 0xFFFF) / 65535.0
        let sat = 0.65 + Float(h & 0xFF) / 255.0 * 0.30
        let val = 0.75 + Float((h >> 24) & 0x3F) / 63.0 * 0.20
        return hsvToRgb(hue, sat, val)
    }

    private static func hsvToRgb(_ h: Float, _ s: Float, _ v: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        var i = Int(h * 6.0)
        if i < 0 { i += 6 }
        i = i % 6
        let f = h * 6.0 - Float(Int(h * 6.0))
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)
        let (r, g, b): (Float, Float, Float)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return (toU8(r), toU8(g), toU8(b))
    }

    private static func toU8(_ unit: Float) -> UInt8 {
        UInt8(max(0, min(255, Int((unit * 255.0).rounded()))))
    }

    // MARK: - FreeSurfer table (aseg + Desikan aparc)

    // Stored as packed 0xRRGGBB for Sendable conformance.
    private static let freeSurferTable: [Int: UInt32] = buildFreeSurferTable()

    private static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    private static func unpack(_ v: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8(v >> 16), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    // Desikan-Killiany cortical colours, indexed by (label % 1000), 0..35.
    // lh = 1000+i, rh = 2000+i, both hemispheres share the same colour.
    // Values from FreeSurferColorLUT.txt. Port of MIQ-Win's Cortical[] array.
    private static let cortical: [(UInt8, UInt8, UInt8)] = [
        (25, 5, 25),     // 0  unknown
        (25, 100, 40),   // 1  bankssts
        (125, 100, 160), // 2  caudalanteriorcingulate
        (100, 25, 0),    // 3  caudalmiddlefrontal
        (120, 70, 50),   // 4  corpuscallosum
        (220, 20, 100),  // 5  cuneus
        (220, 20, 10),   // 6  entorhinal
        (180, 220, 140), // 7  fusiform
        (220, 60, 220),  // 8  inferiorparietal
        (180, 40, 120),  // 9  inferiortemporal
        (140, 20, 140),  // 10 isthmuscingulate
        (20, 30, 140),   // 11 lateraloccipital
        (35, 75, 50),    // 12 lateralorbitofrontal
        (225, 140, 140), // 13 lingual
        (200, 35, 75),   // 14 medialorbitofrontal
        (160, 100, 50),  // 15 middletemporal
        (20, 220, 60),   // 16 parahippocampal
        (60, 220, 60),   // 17 paracentral
        (220, 180, 140), // 18 parsopercularis
        (20, 100, 50),   // 19 parsorbitalis
        (220, 60, 20),   // 20 parstriangularis
        (120, 100, 60),  // 21 pericalcarine
        (220, 20, 20),   // 22 postcentral
        (220, 180, 220), // 23 posteriorcingulate
        (60, 20, 220),   // 24 precentral
        (160, 140, 180), // 25 precuneus
        (80, 20, 140),   // 26 rostralanteriorcingulate
        (75, 50, 125),   // 27 rostralmiddlefrontal
        (20, 220, 160),  // 28 superiorfrontal
        (20, 180, 140),  // 29 superiorparietal
        (140, 220, 220), // 30 superiortemporal
        (80, 160, 20),   // 31 supramarginal
        (100, 0, 100),   // 32 frontalpole
        (70, 70, 70),    // 33 temporalpole
        (150, 150, 200), // 34 transversetemporal
        (255, 192, 32),  // 35 insula
    ]

    private static func buildFreeSurferTable() -> [Int: UInt32] {
        var d: [Int: UInt32] = [
            // aseg subcortical / structural labels — port of MIQ-Win's BuildFreeSurfer()
            2:   pack(245, 245, 245), // Left-Cerebral-White-Matter
            3:   pack(205, 62,  78),  // Left-Cerebral-Cortex
            4:   pack(120, 18,  134), // Left-Lateral-Ventricle
            5:   pack(196, 58,  250), // Left-Inf-Lat-Vent
            7:   pack(220, 248, 164), // Left-Cerebellum-White-Matter
            8:   pack(230, 148, 34),  // Left-Cerebellum-Cortex
            10:  pack(0,   118, 14),  // Left-Thalamus
            11:  pack(122, 186, 220), // Left-Caudate
            12:  pack(236, 13,  176), // Left-Putamen
            13:  pack(12,  48,  255), // Left-Pallidum
            14:  pack(204, 182, 142), // 3rd-Ventricle
            15:  pack(42,  204, 164), // 4th-Ventricle
            16:  pack(119, 159, 176), // Brain-Stem
            17:  pack(220, 216, 20),  // Left-Hippocampus
            18:  pack(103, 255, 255), // Left-Amygdala
            24:  pack(60,  60,  60),  // CSF
            26:  pack(255, 165, 0),   // Left-Accumbens-area
            28:  pack(165, 42,  42),  // Left-VentralDC
            30:  pack(160, 32,  240), // Left-vessel
            31:  pack(0,   200, 200), // Left-choroid-plexus
            41:  pack(245, 245, 245), // Right-Cerebral-White-Matter
            42:  pack(205, 62,  78),  // Right-Cerebral-Cortex
            43:  pack(120, 18,  134), // Right-Lateral-Ventricle
            44:  pack(196, 58,  250), // Right-Inf-Lat-Vent
            46:  pack(220, 248, 164), // Right-Cerebellum-White-Matter
            47:  pack(230, 148, 34),  // Right-Cerebellum-Cortex
            49:  pack(0,   118, 14),  // Right-Thalamus
            50:  pack(122, 186, 220), // Right-Caudate
            51:  pack(236, 13,  176), // Right-Putamen
            52:  pack(13,  48,  255), // Right-Pallidum  (13 not 12 — see LUT)
            53:  pack(220, 216, 20),  // Right-Hippocampus
            54:  pack(103, 255, 255), // Right-Amygdala
            58:  pack(255, 165, 0),   // Right-Accumbens-area
            60:  pack(165, 42,  42),  // Right-VentralDC
            62:  pack(160, 32,  240), // Right-vessel
            63:  pack(0,   200, 221), // Right-choroid-plexus (221 not 200)
            72:  pack(120, 190, 150), // 5th-Ventricle
            77:  pack(200, 70,  255), // WM-hypointensities
            80:  pack(164, 108, 226), // non-WM-hypointensities
            85:  pack(234, 169, 30),  // Optic-Chiasm
            251: pack(0,   0,   64),  // CC_Posterior
            252: pack(0,   0,   112), // CC_Mid_Posterior
            253: pack(0,   0,   160), // CC_Central
            254: pack(0,   0,   208), // CC_Mid_Anterior
            255: pack(0,   0,   255), // CC_Anterior
        ]
        // Desikan aparc cortical labels: lh = 1000+i, rh = 2000+i, same colour.
        for (i, c) in cortical.enumerated() {
            let packed = pack(c.0, c.1, c.2)
            d[1000 + i] = packed
            d[2000 + i] = packed
        }
        return d
    }
}
