import AppKit
import SwiftUI

/// Developer aid: renders every widget's tile and detail view to a PNG, so
/// their layout can be checked without the panel on screen.
@MainActor
enum Snapshot {
    static func write(widgets: [any DockWidget], to url: URL) {
        let content = VStack(alignment: .leading, spacing: 20) {
            ForEach([ColorScheme.dark, .light], id: \.self) { scheme in
                bar(widgets, scheme: scheme)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(widgets.indices, id: \.self) { index in
                    widgets[index].detailView
                        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .padding(24)
        .background(Color(white: 0.42))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    /// Captures the live panel window exactly as the window server composites
    /// it. An app may always image its own windows, so this needs no
    /// screen-recording permission. The call is looked up at runtime because
    /// the SDK no longer declares it for Swift.
    static func capture(window: NSWindow, to url: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // A window that has never been on screen has no number yet, and
        // nothing to capture.
        guard window.windowNumber > 0,
              let symbol = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage")
        else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let bestResolution: UInt32 = 1 << 3
        guard let image = createImage(.null, includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    private static func bar(_ widgets: [any DockWidget], scheme: ColorScheme) -> some View {
        HStack(spacing: 4) {
            ForEach(widgets.indices, id: \.self) { index in
                widgets[index].tileView.frame(width: 57 * widgets[index].info.widthFactor, height: 57)
            }
        }
        .padding(8)
        .background(
            scheme == .dark ? Color(white: 0.2) : Color(white: 0.9),
            in: RoundedRectangle(cornerRadius: 21, style: .continuous)
        )
        .environment(\.colorScheme, scheme)
    }
}
