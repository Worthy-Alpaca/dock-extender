@preconcurrency import Darwin
import SwiftUI

// MARK: - Sampling

struct NetworkReading: Sendable {
    /// Bytes per second.
    var down = 0.0
    var up = 0.0
    /// Bytes transferred since the app started.
    var sessionDown: UInt64 = 0
    var sessionUp: UInt64 = 0
}

/// Sums the kernel's 64-bit byte counters over the physical network
/// interfaces and turns the change between reads into a rate.
/// Only used on the sampling queue.
final class NetworkSampler: @unchecked Sendable {
    private typealias Counters = (received: UInt64, sent: UInt64)

    private var capacity = 32 * 1024
    private var buffer: UnsafeMutableRawPointer
    private var previous: (counters: Counters, time: UInt64)?
    private var session: Counters = (0, 0)
    /// Interface index -> whether its traffic counts.
    private var counted: [UInt16: Bool] = [:]

    init() {
        buffer = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    func read() -> NetworkReading {
        guard let counters = readCounters() else { return NetworkReading() }
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previous = (counters, now) }

        var reading = NetworkReading(sessionDown: session.received, sessionUp: session.sent)
        guard let previous, now > previous.time else { return reading }

        // A counter going backwards means an interface was reset; skip that tick.
        let received = counters.received >= previous.counters.received ? counters.received - previous.counters.received : 0
        let sent = counters.sent >= previous.counters.sent ? counters.sent - previous.counters.sent : 0
        let seconds = Double(now - previous.time) / 1_000_000_000

        session.received += received
        session.sent += sent
        reading.down = Double(received) / seconds
        reading.up = Double(sent) / seconds
        reading.sessionDown = session.received
        reading.sessionUp = session.sent
        return reading
    }

    private func readCounters() -> Counters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = capacity
        while sysctl(&mib, UInt32(mib.count), buffer, &length, nil, 0) != 0 {
            // The interface list outgrew the buffer: double it and retry.
            guard errno == ENOMEM, capacity < 4 * 1024 * 1024 else { return nil }
            capacity *= 2
            buffer.deallocate()
            buffer = .allocate(byteCount: capacity, alignment: 16)
            length = capacity
        }

        var total: Counters = (0, 0)
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0 else { break }

            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if isCounted(message.ifm_index), message.ifm_flags & IFF_UP != 0 {
                    total.received += message.ifm_data.ifi_ibytes
                    total.sent += message.ifm_data.ifi_obytes
                }
            }
            offset += messageLength
        }
        return total
    }

    /// Counts Ethernet/Wi-Fi ("en") and cellular ("pdp_ip") interfaces only.
    /// Loopback, AirDrop and VPN tunnels would double-count the same traffic.
    private func isCounted(_ index: UInt16) -> Bool {
        if let known = counted[index] {
            return known
        }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let result: Bool
        if if_indextoname(UInt32(index), &name) != nil {
            let interface = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result = interface.hasPrefix("en") || interface.hasPrefix("pdp_ip")
        } else {
            result = false
        }
        counted[index] = result
        return result
    }
}

// MARK: - Widget

@MainActor
@Observable
final class NetworkModel {
    private(set) var reading = NetworkReading()
    private(set) var downHistory = History()
    private(set) var upHistory = History()

    func update(_ reading: NetworkReading) {
        self.reading = reading
        downHistory.push(reading.down)
        upHistory.push(reading.up)
    }

    /// Shared top-of-graph value so both lines use one scale. The floor keeps
    /// background chatter from filling the graph when the link is idle.
    var graphCeiling: Double {
        max(downHistory.peak, upHistory.peak, 50_000)
    }
}

@MainActor
final class NetworkWidget: DockWidget {
    let info = WidgetInfo(id: "network", title: "Network", symbol: "network")

    private nonisolated let sampler = NetworkSampler()
    private let model = NetworkModel()

    nonisolated func read() -> NetworkReading {
        sampler.read()
    }

    func apply(_ reading: NetworkReading) {
        model.update(reading)
    }

    var tile: some View {
        NetworkTile(model: model)
    }

    var detail: some View {
        NetworkDetail(model: model)
    }
}

// MARK: - Views

private let downTint = Color.teal
private let upTint = Color.orange

private struct NetworkTile: View {
    let model: NetworkModel
    @Environment(\.tileScale) private var scale

    var body: some View {
        VStack(spacing: 2 * scale) {
            row("↓", model.reading.down, downTint)
            row("↑", model.reading.up, upTint)
            ZStack {
                Sparkline(values: model.downHistory.values, ceiling: model.graphCeiling, tint: downTint)
                Sparkline(values: model.upHistory.values, ceiling: model.graphCeiling, tint: upTint)
            }
            .graphWell()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tilePadding()
    }

    private func row(_ arrow: String, _ rate: Double, _ tint: Color) -> some View {
        HStack(spacing: 2 * scale) {
            Text(arrow)
                .font(.system(size: 9 * scale, weight: .bold))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            Text(Format.compactRate(rate))
                .font(.system(size: 9.5 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct NetworkDetail: View {
    let model: NetworkModel

    var body: some View {
        let reading = model.reading
        DetailCard(title: "Network", symbol: "network", headline: Format.rate(reading.down + reading.up)) {
            ZStack {
                Sparkline(values: model.downHistory.values, ceiling: model.graphCeiling, tint: downTint)
                Sparkline(values: model.upHistory.values, ceiling: model.graphCeiling, tint: upTint)
            }
            .detailGraph()

            Divider()
            StatRow(label: "Download", value: Format.rate(reading.down), tint: downTint)
            StatRow(label: "Upload", value: Format.rate(reading.up), tint: upTint)
            StatRow(label: "Downloaded this session", value: Format.bytes(reading.sessionDown))
            StatRow(label: "Uploaded this session", value: Format.bytes(reading.sessionUp))
        }
    }
}
