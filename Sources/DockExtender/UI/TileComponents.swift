import SwiftUI

/// The standard tile: a caption and a value on top, a graph underneath.
/// Most widgets only need to fill in these three things.
struct MetricTile<Graph: View>: View {
    let label: String
    let value: String
    @ViewBuilder let graph: Graph

    @Environment(\.tileScale) private var scale

    var body: some View {
        VStack(spacing: 3 * scale) {
            // Sized so "RAM" next to "100%" fits a Dock-icon-wide tile; only the
            // value may shrink, so captions stay the same size across tiles.
            HStack(alignment: .firstTextBaseline, spacing: 1 * scale) {
                Text(label)
                    .font(.system(size: 8 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
            }
            .lineLimit(1)

            graph
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tilePadding()
    }
}

extension View {
    /// Inset shared by every tile so their contents line up.
    func tilePadding() -> some View {
        modifier(TilePadding())
    }

    /// Rounded backing for a graph, so an empty graph still reads as one.
    func graphWell() -> some View {
        modifier(GraphWell())
    }
}

private struct TilePadding: ViewModifier {
    @Environment(\.tileScale) private var scale

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4.5 * scale)
            .padding(.vertical, 5 * scale)
    }
}

private struct GraphWell: ViewModifier {
    @Environment(\.tileScale) private var scale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
        content
            .background(.primary.opacity(0.08), in: shape)
            .clipShape(shape)
    }
}

// MARK: - Detail popover building blocks

/// Frame for a widget's detail popover: icon, title and headline value,
/// followed by whatever the widget wants to show.
struct DetailCard<Content: View>: View {
    let title: String
    let symbol: String
    let headline: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(headline)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            content
        }
        .padding(14)
        .frame(width: 264)
    }
}

/// One "label ... value" line in a detail popover.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let tint {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

extension View {
    /// Sizing and backing for the large graph at the top of a detail popover.
    func detailGraph(height: CGFloat = 48) -> some View {
        frame(height: height)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
