import Foundation

/// Compact number formatting for tiles. Hand-rolled because these run on every
/// sample and the Foundation formatters are comparatively heavy.
enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// "12.3 GB". Memory uses binary units like Activity Monitor; disk and
    /// network use decimal units like Finder.
    static func bytes(_ value: UInt64, binary: Bool = false) -> String {
        scaled(Double(value), base: binary ? 1024 : 1000, units: ["B", "KB", "MB", "GB", "TB"])
    }

    /// "1.2 MB/s". Starts at KB so an idle link reads "0 KB/s" instead of
    /// flickering through single bytes.
    static func rate(_ bytesPerSecond: Double) -> String {
        compactRate(bytesPerSecond) + "/s"
    }

    /// "1.2 MB", for places too narrow for the "/s".
    static func compactRate(_ bytesPerSecond: Double) -> String {
        scaled(max(bytesPerSecond, 0) / 1000, base: 1000, units: ["KB", "MB", "GB"])
    }

    /// "45 s", "12 min", "3 h 05 min": how long something has been going on.
    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = Int(max(seconds, 0))
        switch seconds {
        case ..<60: return "\(seconds) s"
        case ..<3600: return "\(seconds / 60) min"
        default: return String(format: "%d h %02d min", seconds / 3600, seconds % 3600 / 60)
        }
    }

    private static func scaled(_ value: Double, base: Double, units: [String]) -> String {
        var value = value
        var index = 0
        while value >= base, index < units.count - 1 {
            value /= base
            index += 1
        }
        let wholeNumber = value >= 100 || index == 0
        return String(format: wholeNumber ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
