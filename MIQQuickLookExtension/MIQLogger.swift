import Foundation
import OSLog

enum MIQLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "net.marco-duering.miq.extension"

    static func make(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
