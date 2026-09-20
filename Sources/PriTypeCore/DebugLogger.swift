import Foundation

#if DEBUG
import os.log
#endif

// MARK: - DebugLogger

/// Debug-only logger that is completely disabled in release builds
///
/// This logger uses conditional compilation to ensure that:
/// - In DEBUG builds: Full logging to file and console
/// - In RELEASE builds: All logging functions are no-ops (empty functions)
///
/// ## Security
/// For input methods, logging user keystrokes could be a security risk.
/// This implementation guarantees that **no logging code exists** in release builds,
/// not just disabled - the code is literally not compiled.
///
/// ## Usage
/// ```swift
/// DebugLogger.log("User pressed key")  // Only logs in DEBUG builds
/// ```
/// - Note: The `@unchecked` conformance covers static storage that `logQueue`
///   serializes — a serial queue is the synchronization here, and routing it
///   through a lock as well would buy nothing. The one static read off-queue is
///   `emittedLineObserver`, which is DEBUG-only and documented where it sits.
public final class DebugLogger: @unchecked Sendable {
    
    #if DEBUG
    
    // =========================================================================
    // MARK: - Debug Build (Full implementation)
    // =========================================================================
    
    // MARK: - Private Properties
    
    /// System logger for console output (fallback)
    private static let osLog = OSLog(subsystem: "com.pritype.inputmethod", category: "Debug")
    
    /// Serial queue for thread-safe file operations
    private static let logQueue = DispatchQueue(label: "com.pritype.logger", qos: .utility)
    
    /// Cached file handle for performance
    /// - Note: Protected by logQueue serial dispatch
    nonisolated(unsafe) private static var cachedHandle: FileHandle?

    /// Bytes in the file the cached handle is open on.
    ///
    /// Rotation used to ask the filesystem for the size, but only when there was
    /// no cached handle — which is true exactly once per process. An input method
    /// runs for days, so after its first log line the 5 MiB limit was never
    /// checked again and the file grew without end. The size is counted here
    /// instead: it is known at every write, and it stays known.
    /// - Note: Protected by logQueue serial dispatch
    nonisolated(unsafe) private static var bytesInCurrentFile = 0

    private static let maxLogFileSize = 5 * 1024 * 1024

    /// Where the logger writes, and when it rotates.
    ///
    /// The whole logger is DEBUG-only, so this seam does not exist in a Release
    /// build. It lets a test point the logger at a temporary file and shrink the
    /// limit, rather than writing megabytes into the user's own log to find out
    /// whether rotation happens.
    struct TestOverrides {
        var path: String?
        var rotationLimit: Int?
    }

    /// - Note: Set from a test before it logs; read on logQueue.
    ///
    /// Setting this closes the file currently open, and waits for the queue to
    /// finish what it was writing. A handle refers to a file, not to a path: left
    /// open across a redirection it would go on writing into the old one, and a
    /// test that then replaces its new file on disk would be counting bytes in a
    /// file nothing is writing to.
    static var testOverrides: TestOverrides {
        get { logQueue.sync { storedTestOverrides } }
        set {
            logQueue.sync {
                storedTestOverrides = newValue
                closeCurrentFile()
            }
        }
    }

    /// - Note: Protected by logQueue serial dispatch.
    nonisolated(unsafe) private static var storedTestOverrides = TestOverrides()

    private static var currentLogPath: String { storedTestOverrides.path ?? PriTypeConfig.logPath }
    private static var rotationLimit: Int { storedTestOverrides.rotationLimit ?? maxLogFileSize }

    /// Wait for everything logged so far to reach the file (tests only).
    static func flushPendingWrites() {
        logQueue.sync {}
    }
    
    /// Flag to prevent infinite recursion on logging errors
    /// - Note: Protected by logQueue serial dispatch
    nonisolated(unsafe) private static var isLoggingError = false
    
    // MARK: - Public API
    
    /// Cached date formatter for performance (avoid repeated allocations)
    ///
    /// - Note: Only ever touched on `logQueue`. That used to be written here and
    ///   not be true: `log()` formatted the timestamp on the caller's thread,
    ///   which for this logger is every thread there is, including the event tap.
    ///   The caller now takes a `Date` — a value, and cheap — and the formatting
    ///   happens with the write. The line's time is still when `log()` was
    ///   called, not when the queue got to it.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
    
    /// Every line this logger emits, handed over before it is written. Exists so a
    /// test can assert what does NOT appear in the DEFAULT Debug output — whether
    /// input the user typed reached the log through some path that skipped
    /// `logSensitive`. DEBUG only, and nil unless a test installs it.
    ///
    /// - Note: This one is read on the caller's thread rather than on `logQueue`,
    ///   which for this logger means any thread — a test installs it before it
    ///   logs and removes it after, and nothing in the app ever sets it. Every
    ///   other static here is touched only from inside `logQueue`.
    nonisolated(unsafe) public static var emittedLineObserver: (@Sendable (String) -> Void)?

    /// Log a debug message to file with console fallback
    /// - Parameter msg: The message to log
    /// - Note: Thread-safe. Falls back to system console if file logging fails.
    /// - Important: This function is only available in DEBUG builds.
    public static func log(_ msg: String) {
        emittedLineObserver?(msg)
        let calledAt = Date()

        logQueue.async {
            let logMsg = "[\(dateFormatter.string(from: calledAt))] \(msg)\n"
            guard let data = logMsg.data(using: .utf8) else {
                logToConsole("Failed to encode log message: \(msg)", isError: true)
                return
            }
            
            do {
                try writeToFile(data: data)
            } catch {
                // Fallback to console on file error (avoid infinite recursion)
                if !isLoggingError {
                    isLoggingError = true
                    logToConsole("File logging failed: \(error.localizedDescription)", isError: true)
                    logToConsole(msg, isError: false)
                    isLoggingError = false
                }
            }
        }
    }
    
    /// Log sensitive input data (like keystrokes or composed strings).
    /// By default, the actual content is redacted even in DEBUG builds to prevent accidental leakage.
    /// To see actual input logs, compile with `-D PRITYPE_UNREDACT_SENSITIVE_LOGS`.
    public static func logSensitive(_ msg: String, sensitiveContent: String) {
        #if PRITYPE_UNREDACT_SENSITIVE_LOGS
        log("\(msg): \(sensitiveContent)")
        #else
        log("\(msg): [REDACTED]")
        #endif
    }
    
    /// Log an error with context
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - context: Additional context about where the error occurred
    /// - Important: This function is only available in DEBUG builds.
    public static func logError(_ error: Error, context: String) {
        log("ERROR [\(context)]: \(error.localizedDescription)")
    }
    
    // MARK: - Private Methods
    
    private static func writeToFile(data: Data) throws {
        let path = currentLogPath
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()

        // Ensure directory exists
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // The log can be deleted under a running process — clearing it between two
        // debugging runs is routine. An open handle would keep writing into the
        // unlinked file, where nothing can read it, so the handle is dropped and a
        // new file made. This costs one existence check per line, on the logger's
        // own utility queue, which is worth more than it saves.
        if !fileManager.fileExists(atPath: path) {
            closeCurrentFile()
            fileManager.createFile(atPath: path, contents: nil)
        }

        if cachedHandle == nil {
            cachedHandle = FileHandle(forWritingAtPath: path)
            // A file left by an earlier run starts this count where it left off, so
            // an already-oversized log rotates on its first line rather than never.
            bytesInCurrentFile = cachedHandle.flatMap { try? $0.seekToEnd() }.map(Int.init) ?? 0
        }

        guard let handle = cachedHandle else {
            throw LoggingError.failedToOpenFile
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        bytesInCurrentFile += data.count

        if bytesInCurrentFile > rotationLimit {
            try rotate(at: url)
        }
    }

    /// Close the file, move it aside and start a new one. Rotating AFTER the write
    /// rather than before lets the limit be what it says it is: a cap on the file
    /// left behind, overshot by at most the one line that crossed it.
    private static func rotate(at url: URL) throws {
        closeCurrentFile()
        let fileManager = FileManager.default
        let rotatedURL = url.deletingPathExtension().appendingPathExtension("log.1")
        try? fileManager.removeItem(at: rotatedURL)
        try fileManager.moveItem(at: url, to: rotatedURL)
        fileManager.createFile(atPath: url.path, contents: nil)
    }

    private static func closeCurrentFile() {
        try? cachedHandle?.close()
        cachedHandle = nil
        bytesInCurrentFile = 0
    }
    
    private static func logToConsole(_ msg: String, isError: Bool) {
        if isError {
            os_log(.error, log: osLog, "%{public}@", msg)
        } else {
            os_log(.debug, log: osLog, "%{public}@", msg)
        }
    }
    
    // MARK: - Error Types
    
    private enum LoggingError: Error, LocalizedError {
        case failedToOpenFile
        
        var errorDescription: String? {
            switch self {
            case .failedToOpenFile:
                return "Failed to open log file for writing"
            }
        }
    }
    
    #else
    
    // =========================================================================
    // MARK: - Release Build (No-op implementations)
    // =========================================================================
    
    /// No-op in release builds - string argument is never evaluated
    /// - Parameter msg: Autoclosure - never evaluated in release builds
    @inlinable
    public static func log(_ msg: @autoclosure () -> String) {
        // Explicitly empty for zero overhead in release
    }
    
    /// No-op in release builds - arguments are never evaluated
    @inlinable
    public static func logSensitive(_ msg: @autoclosure () -> String, sensitiveContent: @autoclosure () -> String) {
        // Explicitly empty for zero overhead in release
    }
    
    /// No-op in release builds - arguments are never evaluated
    /// - Parameters:
    ///   - error: Autoclosure - never evaluated in release builds
    ///   - context: Autoclosure - never evaluated in release builds
    @inlinable
    public static func logError(_ error: @autoclosure () -> Error, context: @autoclosure () -> String) {
        // Intentionally empty - no logging in release builds for security
    }
    
    #endif
}
