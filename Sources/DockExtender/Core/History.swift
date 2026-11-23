import Foundation

/// Fixed-length record of recent values, oldest first. Backs the sparklines.
struct History: Equatable, Sendable {
    static let defaultCapacity = 60

    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int = History.defaultCapacity) {
        self.capacity = capacity
        values.reserveCapacity(capacity)
    }

    mutating func push(_ value: Double) {
        if values.count == capacity {
            values.removeFirst()
        }
        values.append(value)
    }

    var peak: Double { values.max() ?? 0 }
}
