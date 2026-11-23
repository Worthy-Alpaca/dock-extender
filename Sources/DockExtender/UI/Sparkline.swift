import SwiftUI

/// A small filled line graph of recent values, newest at the right edge.
struct Sparkline: View {
    let values: [Double]
    /// Number of samples that span the full width.
    var capacity = History.defaultCapacity
    /// Value drawn at the top of the graph. Nil scales to the tallest sample.
    var ceiling: Double? = 1
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 1.2

    var body: some View {
        let top = max(ceiling ?? (values.max() ?? 0), .leastNonzeroMagnitude)
        ZStack {
            SparklineShape(values: values, capacity: capacity, ceiling: top, inset: lineWidth / 2, closed: true)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.5), tint.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            SparklineShape(values: values, capacity: capacity, ceiling: top, inset: lineWidth / 2, closed: false)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
        }
    }
}

private struct SparklineShape: Shape {
    let values: [Double]
    let capacity: Int
    let ceiling: Double
    /// Keeps the stroke from being clipped at the top and bottom edges.
    let inset: CGFloat
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, capacity > 1 else { return path }

        let step = rect.width / CGFloat(capacity - 1)
        let left = rect.maxX - step * CGFloat(values.count - 1)
        let height = rect.height - 2 * inset
        for (index, value) in values.enumerated() {
            let fraction = CGFloat(min(max(value / ceiling, 0), 1))
            let point = CGPoint(
                x: left + step * CGFloat(index),
                y: rect.maxY - inset - fraction * height
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: left, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// A horizontal fill bar for "how full" values.
struct BarGauge: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(tint).frame(width: max(width, geometry.size.height))
            }
        }
    }
}
