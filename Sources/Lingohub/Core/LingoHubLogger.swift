import Foundation
import os

/**
 Log level for LingoHub SDK
 */
public enum LogLevel: Sendable {
    /// No debug logging
    case none
    /// Full debug logging with all details
    case full
}

/// SDK logger. Callable from any thread; the log level is protected by a lock.
internal final class LingoHubLogger: @unchecked Sendable {
    static let shared: LingoHubLogger = LingoHubLogger()
    static private let logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lingohub", category: "LingoHub")

    private let lock = NSLock()
    private var _logLevel: LogLevel = .none

    internal var logLevel: LogLevel {
        get { lock.lh_withLock { _logLevel } }
        set { lock.lh_withLock { _logLevel = newValue } }
    }

    private init() {} // Prevent external instantiation

    internal func log(_ message: String, file: String = #file, function: String = #function, line: UInt = #line) {
        if logLevel == .full {
            let fileName = (file as NSString).lastPathComponent
            LingoHubLogger.logger.debug("[\(fileName):\(line)] \(message)")
        }
    }
}
