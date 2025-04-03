import Foundation
import os

/**
 Log level for Lingohub SDK
 */
public enum LogLevel {
    /// No debug logging
    case none
    /// Full debug logging with all details
    case full
}

internal class LingohubLogger {
    static let shared: LingohubLogger = LingohubLogger()
    static private let logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lingohub", category: "Lingohub")

    internal var logLevel: LogLevel = .none
    private init() {} // Prevent external instantiation

    internal func log(_ message: String, file: String = #file, function: String = #function, line: UInt = #line) {
        if logLevel == .full {
            let fileName = (file as NSString).lastPathComponent
            LingohubLogger.logger.debug("[\(fileName):\(line)] \(message)")
        }
    }
}
