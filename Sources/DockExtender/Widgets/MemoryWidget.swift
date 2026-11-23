@preconcurrency import Darwin
import SwiftUI

// MARK: - Sampling

struct MemoryReading: Sendable {
    var total: UInt64 = 0
    /// App + wired + compressed: the "Memory Used" figure in Activity Monitor.
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File cache the system gives back on demand.
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// Kernel memory pressure: 1 normal, 2 warning, 4 critical.
    var pressure: Int32 = 1

    var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

/// Only used on the sampling queue.
final class MemorySampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let total = ProcessInfo.processInfo.physicalMemory
    private let pageSize: UInt64

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = size > 0 ? UInt64(size) : 16384
    }

    func read() -> MemoryReading {
        var reading = MemoryReading(total: total)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return reading }

        let purgeable = UInt64(stats.purgeable_count)
        let anonymous = UInt64(stats.internal_page_count)
        reading.app = (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize
        reading.wired = UInt64(stats.wire_count) * pageSize
        reading.compressed = UInt64(stats.compressor_page_count) * pageSize
        reading.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
        reading.used = reading.app + reading.wired + reading.compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            reading.swapUsed = swap.xsu_used
        }

        var pressure: Int32 = 1
        var pressureSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0 {
            reading.pressure = pressure
        }
        return reading
    }
}

// MARK: - Widget

@MainActor
@Observable
final class MemoryModel {
    private(set) var reading = MemoryReading()
    private(set) var history = History()

    func update(_ reading: MemoryReading) {
        self.reading = reading
        history.push(reading.usedFraction)
    }

    /// Green, yellow or red, following the system's own memory pressure.
    var tint: Color {
        switch reading.pressure {
        case 4...: return .red
        case 2, 3: return .yellow
        default: return .green
        }
    }

    var pressureName: String {
        switch reading.pressure {
        case 4...: return "Critical"
        case 2, 3: return "Warning"
        default: return "Normal"
        }
    }
}

@MainActor
final class MemoryWidget: DockWidget {
    let info = WidgetInfo(id: "memory", title: "Memory", symbol: "memorychip")

    private nonisolated let sampler = MemorySampler()
    private let model = MemoryModel()

    nonisolated func read() -> MemoryReading {
        sampler.read()
    }

    func apply(_ reading: MemoryReading) {
        model.update(reading)
    }

    var tile: some View {
        MemoryTile(model: model)
    }

    var detail: some View {
        MemoryDetail(model: model)
    }
}

// MARK: - Views

private struct MemoryTile: View {
    let model: MemoryModel

    var body: some View {
        MetricTile(label: "RAM", value: Format.percent(model.reading.usedFraction)) {
            Sparkline(values: model.history.values, tint: model.tint)
                .graphWell()
        }
    }
}

private struct MemoryDetail: View {
    let model: MemoryModel

    var body: some View {
        let reading = model.reading
        DetailCard(title: "Memory", symbol: "memorychip", headline: Format.percent(reading.usedFraction)) {
            Sparkline(values: model.history.values, tint: model.tint)
                .detailGraph()

            Text("\(Format.bytes(reading.used, binary: true)) of \(Format.bytes(reading.total, binary: true)) used")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()
            StatRow(label: "App memory", value: Format.bytes(reading.app, binary: true))
            StatRow(label: "Wired", value: Format.bytes(reading.wired, binary: true))
            StatRow(label: "Compressed", value: Format.bytes(reading.compressed, binary: true))
            StatRow(label: "Cached files", value: Format.bytes(reading.cached, binary: true))
            StatRow(label: "Swap used", value: Format.bytes(reading.swapUsed, binary: true))
            StatRow(label: "Pressure", value: model.pressureName, tint: model.tint)
        }
    }
}
