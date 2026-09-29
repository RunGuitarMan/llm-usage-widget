import AppKit
import Foundation

/// Exercises actual NSApplication appearance observation without changing the OS theme.
@main
struct IconChecks {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let controller = AppIconAppearance()
        controller.start(application: app)
        let initial = app.applicationIconImage!
        controller.start(application: app)
        precondition(app.applicationIconImage === initial, "Starting twice must not replace the icon")
        let light = try render(initial, to: root.appendingPathComponent("build/icon-check-light.png"))
        precondition(light > 0.8, "The light appearance must have a light tile")

        app.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        let dark = try render(app.applicationIconImage!, to: root.appendingPathComponent("build/icon-check-dark.png"))
        precondition(dark < 0.3, "Changing app appearance must select the dark tile")
        precondition(light - dark > 0.5, "Appearance observation must update the displayed artwork")

        app.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(100))
        let lightAgain = try render(app.applicationIconImage!, to: root.appendingPathComponent("build/icon-check-light-again.png"))
        precondition(abs(light - lightAgain) < 0.01, "Switching back must restore the same light artwork")
        print("PASS Dock icon: light → dark → light, live appearance observation, idempotent setup")
    }

    @MainActor
    static func render(_ icon: NSImage, to url: URL) throws -> CGFloat {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let background = bitmap.colorAt(x: 128, y: 55)!.usingColorSpace(.sRGB)!
        precondition(background.alphaComponent > 0.99, "Tile must stay opaque")
        let blue = bitmap.colorAt(x: 54, y: 119)!.usingColorSpace(.sRGB)!
        precondition(blue.blueComponent > 0.8 && blue.redComponent < 0.35,
                     "The blue L must keep its position and color")
        precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Canvas corners must be transparent")
        return (background.redComponent + background.greenComponent + background.blueComponent) / 3
    }
}
