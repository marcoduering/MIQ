import Foundation

public enum MIQDatatype: Int16, Sendable {
    case int8 = 256
    case uint8 = 2
    case int16 = 4
    case uint16 = 512
    case int32 = 8
    case uint32 = 768
    case float32 = 16
    case float64 = 64
    case rgb24 = 128
    case rgba32 = 2304

    public var bytesPerVoxel: Int {
        switch self {
        case .int8, .uint8:
            return 1
        case .int16, .uint16:
            return 2
        case .int32, .uint32, .float32:
            return 4
        case .float64:
            return 8
        case .rgb24:
            return 3
        case .rgba32:
            return 4
        }
    }

    public var label: String {
        switch self {
        case .int8: return "int8"
        case .uint8: return "uint8"
        case .int16: return "int16"
        case .uint16: return "uint16"
        case .int32: return "int32"
        case .uint32: return "uint32"
        case .float32: return "float32"
        case .float64: return "float64"
        case .rgb24: return "rgb24"
        case .rgba32: return "rgba32"
        }
    }
}
