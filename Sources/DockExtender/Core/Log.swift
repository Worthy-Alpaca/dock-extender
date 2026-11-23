import Foundation
import QuartzCore

/// Diagnostic output, enabled by launching with `--debug`.
enum Log {
    static let isEnabled = CommandLine.arguments.contains("--debug")

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "%10.3f  %@\n", CACurrentMediaTime(), message())
        FileHandle.standardError.write(Data(line.utf8))
    }
}
