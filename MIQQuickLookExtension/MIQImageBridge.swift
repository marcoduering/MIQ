import AppKit
import MIQCore

enum MIQImageBridge {
    static func makeNSImage(from slice: SliceImage) -> NSImage? {
        switch slice {
        case .grayscale(let img): return makeNSImage(from: img)
        case .rgb(let img): return makeNSImage(from: img)
        }
    }

    private static func makeNSImage(from gray: GrayscaleImage) -> NSImage? {
        guard gray.width > 0, gray.height > 0, gray.pixels.count == gray.width * gray.height else {
            return nil
        }

        let bytesPerRow = gray.width * 4
        var rgba = [UInt8](repeating: 255, count: gray.width * gray.height * 4)
        for i in 0..<(gray.width * gray.height) {
            let g = gray.pixels[i]
            let j = i * 4
            rgba[j] = g
            rgba[j + 1] = g
            rgba[j + 2] = g
        }

        return makeCGImage(rgba: rgba, width: gray.width, height: gray.height, bytesPerRow: bytesPerRow)
    }

    private static func makeNSImage(from rgb: RGBImage) -> NSImage? {
        guard rgb.width > 0, rgb.height > 0, rgb.pixels.count == rgb.width * rgb.height * 3 else {
            return nil
        }

        let bytesPerRow = rgb.width * 4
        var rgba = [UInt8](repeating: 255, count: rgb.width * rgb.height * 4)
        for i in 0..<(rgb.width * rgb.height) {
            let src = i * 3
            let dst = i * 4
            rgba[dst]     = rgb.pixels[src]
            rgba[dst + 1] = rgb.pixels[src + 1]
            rgba[dst + 2] = rgb.pixels[src + 2]
        }

        return makeCGImage(rgba: rgba, width: rgb.width, height: rgb.height, bytesPerRow: bytesPerRow)
    }

    private static func makeCGImage(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> NSImage? {
        let provider = CGDataProvider(data: Data(rgba) as CFData)
        guard let provider,
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
