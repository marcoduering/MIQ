import Foundation
import MIQCore
import OSLog

enum MIQLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "net.marco-duering.miq.extension"

    static func make(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

extension Error {
    /// Which failure this is, safe to log publicly: the `MIQError` case, or the
    /// `NSError` domain and code. The message itself can quote file contents or a
    /// path, so it belongs in a private field next to this.
    var logCode: String {
        guard let error = self as? MIQError else {
            let error = self as NSError
            return "\(error.domain) \(error.code)"
        }
        switch error {
        case .invalidHeaderSize(let value): return "invalidHeaderSize(\(value))"
        case .unsupportedFormatVersion(let value): return "unsupportedFormatVersion(\(value))"
        case .unsupportedDatatype(let value): return "unsupportedDatatype(\(value))"
        case .invalidDimensions: return "invalidDimensions"
        case .truncatedData: return "truncatedData"
        case .decompressionFailed: return "decompressionFailed"
        case .unsupportedFileFormat: return "unsupportedFileFormat"
        case .unsupportedFeature: return "unsupportedFeature"
        case .malformedFile: return "malformedFile"
        }
    }
}
