import Foundation

public enum MIQError: Error, LocalizedError {
    case invalidHeaderSize(Int32)
    case unsupportedFormatVersion(Int32)
    case unsupportedDatatype(Int16)
    case invalidDimensions
    case truncatedData
    case decompressionFailed
    case unsupportedFileFormat

    public var errorDescription: String? {
        switch self {
        case .invalidHeaderSize(let value):
            return "Invalid NIfTI header size: \(value)."
        case .unsupportedFormatVersion(let value):
            return "Unsupported file format version: \(value)."
        case .unsupportedDatatype(let value):
            return "Unsupported datatype code: \(value)."
        case .invalidDimensions:
            return "Invalid or missing image dimensions."
        case .truncatedData:
            return "File appears truncated."
        case .decompressionFailed:
            return "Failed to decompress gzipped data."
        case .unsupportedFileFormat:
            return "Unsupported file format. Expected .nii, .nii.gz, .mgh, .mgz, .mgh.gz, .mif, or .mif.gz."
        }
    }
}
