import CoreGraphics
import Testing
@testable import DockExtender

/// How bars are sized and placed beside the Dock.
struct PanelLayoutTests {
    private let system: [CGFloat] = [1, 1, 1, 1, 1]
    private let audio: [CGFloat] = [3.2]
    /// Tile size in a Dock that is 80 pt deep.
    private let tile: CGFloat = 54

    /// A bottom Dock, 80 pt deep, on a 1728 pt wide screen.
    private func dock(_ span: ClosedRange<CGFloat>) -> DockGeometry {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        return DockGeometry(
            edge: .bottom, autohide: true, tileSize: 55,
            screenFrame: screen, usableFrame: screen, span: span, thickness: 80
        )
    }

    /// The part of the screen edge a bar covers.
    private func extent(_ layout: PanelLayout) -> ClosedRange<CGFloat> {
        let start = layout.shownFrame.minX + layout.barFrame.minX
        return start...(start + layout.barFrame.width)
    }

    /// Lays bars out at one end of the Dock, nearest the Dock first.
    private func layouts(_ dock: DockGeometry, _ side: Settings.Side, _ bars: [[CGFloat]]) throws -> [PanelLayout] {
        let shares = try #require(PanelLayout.share(dock: dock, side: side, among: bars))
        var taken: CGFloat = 0
        return shares.map { share in
            let layout = PanelLayout.make(dock: dock, side: side, share: share, taken: taken)
            taken += layout.length + PanelLayout.spacing
            return layout
        }
    }

    @Test func barIsAsTallAsTheDockAllowsAndSitsAgainstIt() throws {
        let bar = try #require(try layouts(dock(600...1128), .trailing, [audio]).first)
        // The Dock's strip is 80 pt deep; the bar keeps a 5 pt margin on both sides.
        #expect(bar.barFrame.height == 70)
        #expect(bar.tileFrames[0].height == tile)
        #expect(bar.tileFrames[0].width == tile * 3.2)
        #expect(extent(bar).lowerBound == 1128 + PanelLayout.spacing)
        // Hidden, the window is just past the screen edge.
        #expect(bar.hiddenFrame.maxY <= 0)
    }

    @Test func barsWithRoomKeepTheirSize() throws {
        let bars = try layouts(dock(600...1128), .leading, [system, audio])
        #expect(bars[0].tileFrames.allSatisfy { $0.width == tile })
        #expect(bars[1].tileFrames[0].width == tile * 3.2)
    }

    @Test func wideTileGivesWayBeforeAnythingElse() throws {
        let bars = try layouts(dock(420...1308), .leading, [system, audio])
        let wide = bars[1].tileFrames[0].width
        #expect(bars[0].tileFrames.allSatisfy { $0.width == tile })
        #expect(wide < tile * 3.2)
        #expect(wide > tile)
    }

    @Test func crowdedBarsNarrowTogether() throws {
        // 311 pt free at each end: not enough for both bars at full size.
        let bars = try layouts(dock(311...1416), .leading, [system, audio])
        let systemBar = extent(bars[0]), audioBar = extent(bars[1])

        #expect(bars[0].tileFrames.count == 5)
        #expect(bars[1].tileFrames.count == 1)
        // All tiles the same width, narrower than usual but not past the limit.
        let width = bars[0].tileFrames[0].width
        #expect(bars[1].tileFrames[0].width == width)
        #expect(width < tile)
        #expect(width >= tile * 0.7)
        // Still as tall as the Dock.
        #expect(bars[0].tileFrames[0].height == tile)
        // Against the Dock, side by side, on screen.
        #expect(systemBar.upperBound == 311 - PanelLayout.spacing)
        #expect(audioBar.upperBound == systemBar.lowerBound - PanelLayout.spacing)
        #expect(audioBar.lowerBound >= 6)
    }

    @Test func theOtherEndMirrors() throws {
        let bars = try layouts(dock(311...1416), .trailing, [system, audio])
        let systemBar = extent(bars[0]), audioBar = extent(bars[1])
        #expect(systemBar.lowerBound == 1416 + PanelLayout.spacing)
        #expect(audioBar.lowerBound == systemBar.upperBound + PanelLayout.spacing)
        #expect(audioBar.upperBound <= 1728 - 6)
    }

    @Test func barsThatCannotShareAreNotForcedTo() {
        let long = dock(150...1578)
        #expect(PanelLayout.share(dock: long, side: .leading, among: [system, audio]) == nil)
        // One of them alone still fits, squeezed.
        #expect(PanelLayout.share(dock: long, side: .leading, among: [audio]) != nil)
    }

    @Test func barWithNoRoomShowsAsManyTilesAsFit() {
        let bar = PanelLayout.make(dock: dock(150...1578), side: .leading, widthFactors: system)
        #expect(bar.tileFrames.count < 5)
        #expect(bar.tileFrames.count >= 1)
        #expect(extent(bar).lowerBound >= 6)
    }

    @Test func tilesInAVerticalDockAreSquareWhateverTheirWidth() throws {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let dock = DockGeometry(
            edge: .left, autohide: true, tileSize: 55,
            screenFrame: screen, usableFrame: screen, span: 400...700, thickness: 80
        )
        let share = try #require(PanelLayout.share(dock: dock, side: .trailing, among: [audio])?.first)
        #expect(share.lengths == [tile])
        let bar = PanelLayout.make(dock: dock, side: .trailing, share: share, taken: 0)
        #expect(bar.tileFrames[0].size == CGSize(width: tile, height: tile))
        // Hidden, it is past the left edge.
        #expect(bar.hiddenFrame.maxX <= 0)
    }
}
