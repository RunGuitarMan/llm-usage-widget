import AppKit
import Foundation

@main
struct GenerateIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let assets = root.appendingPathComponent("LLMUsage/Resources/Assets.xcassets/AppIcon.appiconset")
        let brand = root.appendingPathComponent("LLMUsage/Resources/Brand")
        let previews = root.appendingPathComponent("build/Previews/Brand")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        var images: [[String: String]] = []
        for appearance in BrandGeometry.Appearance.allCases {
            let suffix = appearance == .light ? "" : "-dark"
            let iconset = root.appendingPathComponent("build/LLMUsage\(suffix).iconset")
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = points * scale
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
                    let context = graphics.cgContext
                    context.translateBy(x: 0, y: CGFloat(pixels))
                    context.scaleBy(x: 1, y: -1)
                    BrandGeometry.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels), context: context,
                                       appearance: appearance)
                    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                    let data = bitmap.representation(using: .png, properties: [:])!
                    try data.write(to: iconset.appendingPathComponent(name))
                    if appearance == .light {
                        try data.write(to: assets.appendingPathComponent(name))
                        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
                    }
                    if pixels == 1024 {
                        try data.write(to: previews.appendingPathComponent("LLMUsageIcon\(suffix).png"))
                    }
                }
            }
            try BrandGeometry.svg(appearance: appearance)
                .write(to: brand.appendingPathComponent("LLMUsageIcon\(suffix).svg"), atomically: true, encoding: .utf8)
            try BrandGeometry.svg(compact: true, appearance: appearance, symbolOnly: true)
                .write(to: brand.appendingPathComponent("LLMUsageSymbol\(suffix).svg"), atomically: true, encoding: .utf8)
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: assets.appendingPathComponent("Contents.json"))
        print("Generated the approved vector LLM monogram in light and dark appearances")
    }
}
