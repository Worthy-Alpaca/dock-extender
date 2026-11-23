import SwiftUI

// MARK: - Sampling

struct DiskReading: Sendable {
    var name = "Disk"
    var total: UInt64 = 0
    /// Free space as Finder reports it, including space macOS can reclaim.
    var available: UInt64 = 0

    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

// MARK: - Widget

@MainActor
@Observable
final class DiskModel {
    private(set) var reading = DiskReading()

    func update(_ reading: DiskReading) {
        self.reading = reading
    }

    var tint: Color {
        switch reading.usedFraction {
        case 0.95...: return .red
        case 0.85...: return .orange
        default: return .indigo
        }
    }
}

@MainActor
final class DiskWidget: DockWidget {
    /// Free space moves slowly; there is no point asking every second.
    let info = WidgetInfo(id: "disk", title: "Disk", symbol: "internaldrive", interval: 30)

    private let model = DiskModel()

    nonisolated func read() -> DiskReading {
        // A fresh URL each time: resource values are cached per URL instance.
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? root.resourceValues(forKeys: keys) else { return DiskReading() }
        return DiskReading(
            name: values.volumeName ?? "Disk",
            total: UInt64(max(values.volumeTotalCapacity ?? 0, 0)),
            available: UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
        )
    }

    func apply(_ reading: DiskReading) {
        model.update(reading)
    }

    var tile: some View {
        DiskTile(model: model)
    }

    var detail: some View {
        DiskDetail(model: model)
    }
}

// MARK: - Views

private struct DiskTile: View {
    let model: DiskModel
    @Environment(\.tileScale) private var scale

    var body: some View {
        let reading = model.reading
        MetricTile(label: "SSD", value: Format.percent(reading.usedFraction)) {
            VStack(spacing: 4 * scale) {
                BarGauge(fraction: reading.usedFraction, tint: model.tint)
                    .frame(height: 6 * scale)
                Text("\(Format.bytes(reading.available)) free")
                    .font(.system(size: 8 * scale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

private struct DiskDetail: View {
    let model: DiskModel

    var body: some View {
        let reading = model.reading
        DetailCard(title: reading.name, symbol: "internaldrive", headline: Format.percent(reading.usedFraction)) {
            BarGauge(fraction: reading.usedFraction, tint: model.tint)
                .frame(height: 8)

            Divider()
            StatRow(label: "Used", value: Format.bytes(reading.used), tint: model.tint)
            StatRow(label: "Available", value: Format.bytes(reading.available))
            StatRow(label: "Capacity", value: Format.bytes(reading.total))
        }
    }
}
