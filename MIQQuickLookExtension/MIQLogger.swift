import Foundation
import OSLog

enum MIQLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "org.mtecs.miq.extension"

    static func make(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
