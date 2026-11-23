import IOKit
import SwiftUI

// MARK: - Sampling

struct GPUReading: Sendable {
    /// Overall busy fraction, 0...1.
    var utilization = 0.0
    var renderer = 0.0
    var tiler = 0.0
    var memoryInUse: UInt64 = 0
    var memoryAllocated: UInt64 = 0
}

/// Reads the statistics every GPU driver publishes in the IO registry.
/// Needs no privileges. Only used on the sampling queue.
final class GPUSampler: @unchecked Sendable {
    /// Marketing name of the GPU, e.g. "Apple M5 Max".
    let name: String
    private var accelerators: [io_registry_entry_t] = []

    init() {
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iterator), service != 0 {
                accelerators.append(service)
            }
            IOObjectRelease(iterator)
        }
        name = accelerators.lazy.compactMap { Self.modelName(of: $0) }.first ?? "GPU"
    }

    deinit {
        accelerators.forEach { IOObjectRelease($0) }
    }

    func read() -> GPUReading {
        var busiest = GPUReading()
        for accelerator in accelerators {
            guard let stats = Self.property("PerformanceStatistics", of: accelerator) as? [String: Any] else { continue }
            func number(_ key: String) -> Double {
                (stats[key] as? NSNumber)?.doubleValue ?? 0
            }
            let reading = GPUReading(
                utilization: number("Device Utilization %") / 100,
                renderer: number("Renderer Utilization %") / 100,
                tiler: number("Tiler Utilization %") / 100,
                memoryInUse: UInt64(number("In use system memory")),
                memoryAllocated: UInt64(number("Alloc system memory"))
            )
            // With more than one GPU, report whichever is working hardest.
            if reading.utilization >= busiest.utilization {
                busiest = reading
            }
        }
        return busiest
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func modelName(of entry: io_registry_entry_t) -> String? {
        switch property("model", of: entry) {
        case let name as String:
            return name
        case let data as Data:
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default:
            return nil
        }
    }
}

// MARK: - Widget

@MainActor
@Observable
final class GPUModel {
    private(set) var reading = GPUReading()
    private(set) var history = History()

    func update(_ reading: GPUReading) {
        self.reading = reading
        history.push(reading.utilization)
    }
}

@MainActor
final class GPUWidget: DockWidget {
    let info = WidgetInfo(id: "gpu", title: "GPU", symbol: "cube.transparent")

    private nonisolated let sampler = GPUSampler()
    private let model = GPUModel()

    nonisolated func read() -> GPUReading {
        sampler.read()
    }

    func apply(_ reading: GPUReading) {
        model.update(reading)
    }

    var tile: some View {
        GPUTile(model: model)
    }

    var detail: some View {
        GPUDetail(model: model, name: sampler.name)
    }
}

// MARK: - Views

private struct GPUTile: View {
    let model: GPUModel

    var body: some View {
        MetricTile(label: "GPU", value: Format.percent(model.reading.utilization)) {
            Sparkline(values: model.history.values, tint: .purple)
                .graphWell()
        }
    }
}

private struct GPUDetail: View {
    let model: GPUModel
    let name: String

    var body: some View {
        let reading = model.reading
        DetailCard(title: name, symbol: "cube.transparent", headline: Format.percent(reading.utilization)) {
            Sparkline(values: model.history.values, tint: .purple)
                .detailGraph()

            Divider()
            StatRow(label: "Renderer", value: Format.percent(reading.renderer))
            StatRow(label: "Tiler", value: Format.percent(reading.tiler))
            StatRow(label: "Memory in use", value: Format.bytes(reading.memoryInUse, binary: true))
            StatRow(label: "Memory allocated", value: Format.bytes(reading.memoryAllocated, binary: true))
        }
    }
}
