@preconcurrency import Darwin
import SwiftUI

// MARK: - Sampling

struct CPUReading: Sendable {
    /// Busy fraction across all cores, 0...1.
    var total = 0.0
    var user = 0.0
    var system = 0.0
    /// Busy fraction per logical core.
    var cores: [Double] = []
    /// 1, 5 and 15 minute load averages.
    var load: [Double] = [0, 0, 0]
}

/// Reads per-core tick counters from the kernel and turns the change since the
/// previous read into usage. Only used on the sampling queue.
final class CPUSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private var previous: [UInt32] = []

    func read() -> CPUReading {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return CPUReading() }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount)).map { UInt32(bitPattern: $0) }
        defer { previous = ticks }

        var reading = CPUReading()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 {
            reading.load = load
        }
        // Usage is a difference between two reads, so the first one has none.
        guard previous.count == ticks.count else {
            reading.cores = [Double](repeating: 0, count: Int(coreCount))
            return reading
        }

        let states = Int(CPU_STATE_MAX)
        func delta(_ core: Int, _ state: Int32) -> Double {
            let index = core * states + Int(state)
            // Counters are 32-bit and wrap; wrapping subtraction handles it.
            return Double(ticks[index] &- previous[index])
        }

        var userSum = 0.0, systemSum = 0.0, totalSum = 0.0
        reading.cores.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let user = delta(core, CPU_STATE_USER) + delta(core, CPU_STATE_NICE)
            let system = delta(core, CPU_STATE_SYSTEM)
            let total = user + system + delta(core, CPU_STATE_IDLE)
            reading.cores.append(total > 0 ? (user + system) / total : 0)
            userSum += user
            systemSum += system
            totalSum += total
        }
        if totalSum > 0 {
            reading.user = userSum / totalSum
            reading.system = systemSum / totalSum
            reading.total = reading.user + reading.system
        }
        return reading
    }
}

/// How the logical cores divide into performance tiers on this Mac.
struct CPUTopology: Sendable {
    struct Cluster: Sendable, Identifiable {
        let name: String
        let cores: Range<Int>
        var id: String { name }
    }

    let clusters: [Cluster]

    /// The kernel numbers cores starting with the least powerful tier, which is
    /// the reverse of how `hw.perflevelN` is ordered.
    static let current: CPUTopology = {
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let levels = Sysctl.int("hw.nperflevels") ?? 0
        var clusters: [Cluster] = []
        var next = 0
        for level in (0..<levels).reversed() {
            guard let count = Sysctl.int("hw.perflevel\(level).logicalcpu"), count > 0 else { continue }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            clusters.append(Cluster(name: name, cores: next..<next + count))
            next += count
        }
        if clusters.isEmpty || next != logical {
            clusters = [Cluster(name: "All", cores: 0..<logical)]
        }
        return CPUTopology(clusters: clusters)
    }()
}

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

// MARK: - Widget

@MainActor
@Observable
final class CPUModel {
    private(set) var reading = CPUReading()
    private(set) var history = History()

    func update(_ reading: CPUReading) {
        self.reading = reading
        history.push(reading.total)
    }
}

@MainActor
final class CPUWidget: DockWidget {
    let info = WidgetInfo(id: "cpu", title: "CPU", symbol: "cpu")

    private nonisolated let sampler = CPUSampler()
    private let model = CPUModel()

    nonisolated func read() -> CPUReading {
        sampler.read()
    }

    func apply(_ reading: CPUReading) {
        model.update(reading)
    }

    var tile: some View {
        CPUTile(model: model)
    }

    var detail: some View {
        CPUDetail(model: model, topology: .current)
    }
}

// MARK: - Views

private struct CPUTile: View {
    let model: CPUModel

    var body: some View {
        MetricTile(label: "CPU", value: Format.percent(model.reading.total)) {
            Sparkline(values: model.history.values, tint: .blue)
                .graphWell()
        }
    }
}

private struct CPUDetail: View {
    let model: CPUModel
    let topology: CPUTopology

    var body: some View {
        let reading = model.reading
        DetailCard(title: "CPU", symbol: "cpu", headline: Format.percent(reading.total)) {
            Sparkline(values: model.history.values, tint: .blue)
                .detailGraph()

            ForEach(topology.clusters) { cluster in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(cluster.name) cores")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    CoreBars(values: cluster.cores.map { $0 < reading.cores.count ? reading.cores[$0] : 0 })
                }
            }

            Divider()
            StatRow(label: "User", value: Format.percent(reading.user))
            StatRow(label: "System", value: Format.percent(reading.system))
            StatRow(label: "Idle", value: Format.percent(1 - reading.total))
            StatRow(
                label: "Load average",
                value: reading.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")
            )
        }
    }
}

/// One vertical bar per core.
private struct CoreBars: View {
    let values: [Double]
    private let height: CGFloat = 26

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { index in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(height: max(2, height * CGFloat(min(max(values[index], 0), 1))))
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
            }
        }
    }
}
