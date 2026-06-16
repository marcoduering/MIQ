import Foundation

public enum SliceImage: Sendable {
    case grayscale(GrayscaleImage)
    case rgb(RGBImage)

    public var width: Int {
        switch self {
        case .grayscale(let img): return img.width
        case .rgb(let img): return img.width
        }
    }

    public var height: Int {
        switch self {
        case .grayscale(let img): return img.height
        case .rgb(let img): return img.height
        }
    }

    public var pixels: [UInt8] {
        switch self {
        case .grayscale(let img): return img.pixels
        case .rgb(let img): return img.pixels
        }
    }
}
