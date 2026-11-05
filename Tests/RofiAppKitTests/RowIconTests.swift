import AppKit
import Testing

@testable import RofiAppKit

// A script's `\0icon` path draws the image itself; anything that is not an
// image falls back to the Finder icon, which other modes always get.
@MainActor @Suite struct RowIconTests {
    private let png: String = {
        let path = NSTemporaryDirectory() + "rofi-row-icon-\(getpid()).png"
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 7, pixelsHigh: 5, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        return path
    }()

    @Test func imagePathDrawsTheImage() {
        #expect(rowIcon(forFile: png, asImage: true).size == NSSize(width: 7, height: 5))
    }

    @Test func nonImagePathFallsBackToTheFinderIcon() {
        let app = "/System/Applications/Calculator.app"
        #expect(rowIcon(forFile: app, asImage: true).size == NSWorkspace.shared.icon(forFile: app).size)
    }

    @Test func finderIconPathNeverPreviewsTheImage() {
        #expect(rowIcon(forFile: png, asImage: false).size == NSWorkspace.shared.icon(forFile: png).size)
        #expect(rowIcon(forFile: png, asImage: false).size != NSSize(width: 7, height: 5))
    }
}
