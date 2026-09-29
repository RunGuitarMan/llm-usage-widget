import Foundation
import CoreGraphics

/// The approved LLM monogram, traced as resolution-independent paths from concept A.
/// App icons, SVG exports and SwiftUI marks all render this same artwork.
enum BrandGeometry {
    enum Appearance: String, CaseIterable { case light, dark }
    struct Color {
        var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        init(_ hex: UInt32, _ alpha: CGFloat = 1) {
            red = CGFloat((hex >> 16) & 255) / 255
            green = CGFloat((hex >> 8) & 255) / 255
            blue = CGFloat(hex & 255) / 255
            self.alpha = alpha
        }
        var cg: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])! }
        var svg: String { String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)) }
    }
    struct Stop { var position: CGFloat; var color: Color }
    enum Fill {
        case solid(Color)
        case linear(CGPoint, CGPoint, [Stop])
        case radial(CGPoint, CGFloat, [Stop])
    }
    struct Shadow { var color: Color; var blur: CGFloat; var offset: CGSize }
    struct Layer {
        var path: CGPath
        var fill: Fill
        var stroke: Color? = nil
        var width: CGFloat = 1
        var shadow: Shadow? = nil
        var clip: CGPath? = nil
    }

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private static func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }
    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
    }
    private static func gradient(_ colors: [UInt32], from: CGPoint, to: CGPoint) -> Fill {
        .linear(from, to, colors.enumerated().map { Stop(position: CGFloat($0.offset) / CGFloat(colors.count - 1), color: Color($0.element)) })
    }

    /// Turn a rounded pen stroke into an ordinary outline, so exported SVGs need no fonts.
    private static func stroke(_ points: [CGPoint], width: CGFloat = 88) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2)
    }

    private static func tile(inset: CGFloat = 0) -> CGPath {
        // Continuous corners, traced from the selected rounded-square enclosure.
        let p = CGMutablePath()
        p.move(to: point(310, 72 + inset))
        p.addLine(to: point(714, 72 + inset))
        p.addCurve(to: point(952 - inset, 310), control1: point(888, 72 + inset), control2: point(952 - inset, 136))
        p.addLine(to: point(952 - inset, 714))
        p.addCurve(to: point(714, 952 - inset), control1: point(952 - inset, 888), control2: point(888, 952 - inset))
        p.addLine(to: point(310, 952 - inset))
        p.addCurve(to: point(72 + inset, 714), control1: point(136, 952 - inset), control2: point(72 + inset, 888))
        p.addLine(to: point(72 + inset, 310))
        p.addCurve(to: point(310, 72 + inset), control1: point(72 + inset, 136), control2: point(136, 72 + inset))
        p.closeSubpath()
        return p
    }

    static func layers(compact: Bool = false, appearance: Appearance = .light,
                       symbolOnly: Bool = false) -> [Layer] {
        let dark = appearance == .dark
        var layers: [Layer] = []
        if !symbolOnly {
            layers.append(Layer(path: tile(),
                fill: gradient(dark ? [0x65707D, 0x3B444E] : [0xDEE1E7, 0xBBC1CA],
                               from: point(350, 72), to: point(680, 952)),
                shadow: compact ? nil : Shadow(color: Color(0x101823, dark ? 0.18 : 0.16),
                                               blur: 22, offset: CGSize(width: 0, height: 13))))
            layers.append(Layer(path: tile(inset: dark ? 12 : 8),
                fill: gradient(dark ? [0x3A4149, 0x2B3138, 0x232930] : [0xF6F7F9, 0xF0F2F5, 0xE9EDF1],
                               from: point(250, 110), to: point(760, 970))))
        }
        let blue = gradient(dark ? [0x2898FF, 0x2085FE] : [0x248FFE, 0x1F84FE],
                            from: point(212, 322), to: point(286, 686))
        let purple = gradient(dark ? [0xCD6CFD, 0xBE5DFD] : [0xA748FD, 0xA443FE],
                              from: point(390, 322), to: point(465, 686))
        let orange = gradient(dark ? [0xFFAD54, 0xFFA044] : [0xFEA84E, 0xFE9B3D],
                              from: point(575, 322), to: point(640, 686))
        let green = gradient(dark ? [0x4EDE65, 0x36D85B] : [0x4FDC65, 0x39D95F],
                             from: point(777, 322), to: point(820, 686))
        let orangeRibbon = gradient([0xFF9C32, 0xFFB145], from: point(594, 366), to: point(700, 506))
        let greenRibbon = gradient(dark ? [0xACE051, 0x8CCD49] : [0xBACA48, 0x9ABC48],
                                   from: point(700, 506), to: point(807, 366))
        let blueL = stroke([point(216, 366), point(216, 642), point(303, 642)])
        let purpleL = stroke([point(390, 366), point(390, 642), point(477, 642)])
        let orangeStem = stroke([point(591, 366), point(591, 642)])
        let greenStem = stroke([point(807, 366), point(807, 642)])
        let descending = stroke([point(591, 366), point(700, 506)])
        let ascending = stroke([point(700, 506), point(807, 366)])
        let letterShadow = compact ? nil : Shadow(color: Color(0x0A1220, dark ? 0.24 : 0.08),
                                                  blur: 8, offset: CGSize(width: 0, height: 4))
        let rim = Color(0xFFFFFF, dark ? 0.14 : 0.20)
        layers.append(Layer(path: blueL, fill: blue, stroke: rim, width: 2, shadow: letterShadow))
        layers.append(Layer(path: purpleL, fill: purple, stroke: rim, width: 2, shadow: letterShadow))
        // Preserve the reference's ribbon overlap: orange in light, green in dark.
        layers.append(Layer(path: dark ? descending : ascending, fill: dark ? orangeRibbon : greenRibbon))
        layers.append(Layer(path: dark ? ascending : descending, fill: dark ? greenRibbon : orangeRibbon))
        layers.append(Layer(path: orangeStem, fill: orange, stroke: rim, width: 2))
        layers.append(Layer(path: greenStem, fill: green, stroke: rim, width: 2))
        return layers
    }

    static func draw(in rect: CGRect, context: CGContext, compact: Bool = false,
                     appearance: Appearance = .light, symbolOnly: Bool = false) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 1024, y: rect.height / 1024)
        let shadowScale = min(rect.width, rect.height) / 1024
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for layer in layers(compact: compact, appearance: appearance, symbolOnly: symbolOnly) {
            context.saveGState()
            if let clip = layer.clip { context.addPath(clip); context.clip() }
            if let shadow = layer.shadow {
                context.saveGState()
                // Quartz shadows use the base coordinate space, not the artwork CTM.
                // Match SVG's downward light direction and scale blur for each icon size.
                context.setShadow(offset: CGSize(width: shadow.offset.width * shadowScale,
                                                  height: -shadow.offset.height * shadowScale),
                                  blur: shadow.blur * shadowScale, color: shadow.color.cg)
                context.addPath(layer.path)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillPath()
                context.restoreGState()
            }
            context.saveGState()
            context.addPath(layer.path); context.clip()
            switch layer.fill {
            case .solid(let color): context.setFillColor(color.cg); context.fill(layer.path.boundingBoxOfPath)
            case .linear(let start, let end, let stops):
                let gradient = CGGradient(colorsSpace: space, colors: stops.map { $0.color.cg } as CFArray, locations: stops.map(\.position))!
                context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial(let center, let radius, let stops):
                let gradient = CGGradient(colorsSpace: space, colors: stops.map { $0.color.cg } as CFArray, locations: stops.map(\.position))!
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
            }
            context.restoreGState()
            if let stroke = layer.stroke {
                context.addPath(layer.path); context.setStrokeColor(stroke.cg); context.setLineWidth(layer.width); context.strokePath()
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    static func svg(compact: Bool = false, appearance: Appearance = .light,
                    symbolOnly: Bool = false) -> String {
        var definitions: [String] = []
        var shapes: [String] = []
        for (index, layer) in layers(compact: compact, appearance: appearance, symbolOnly: symbolOnly).enumerated() {
            let id = "paint\(index)"
            let fill: String
            let opacity: CGFloat
            func stops(_ values: [Stop]) -> String {
                values.map { "<stop offset=\"\(number($0.position))\" stop-color=\"\($0.color.svg)\" stop-opacity=\"\(number($0.color.alpha))\"/>" }.joined()
            }
            switch layer.fill {
            case .solid(let color): fill = color.svg; opacity = color.alpha
            case .linear(let a, let b, let colors):
                definitions.append("<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(number(a.x))\" y1=\"\(number(a.y))\" x2=\"\(number(b.x))\" y2=\"\(number(b.y))\">\(stops(colors))</linearGradient>")
                fill = "url(#\(id))"; opacity = 1
            case .radial(let center, let radius, let colors):
                definitions.append("<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(number(center.x))\" cy=\"\(number(center.y))\" r=\"\(number(radius))\">\(stops(colors))</radialGradient>")
                fill = "url(#\(id))"; opacity = 1
            }
            var attributes = "fill=\"\(fill)\" fill-opacity=\"\(number(opacity))\""
            if let stroke = layer.stroke { attributes += " stroke=\"\(stroke.svg)\" stroke-opacity=\"\(number(stroke.alpha))\" stroke-width=\"\(number(layer.width))\"" }
            if let shadow = layer.shadow {
                let filter = "shadow\(index)"
                definitions.append("<filter id=\"\(filter)\" x=\"-200\" y=\"-200\" width=\"1424\" height=\"1424\" filterUnits=\"userSpaceOnUse\" color-interpolation-filters=\"sRGB\"><feDropShadow dx=\"\(number(shadow.offset.width))\" dy=\"\(number(shadow.offset.height))\" stdDeviation=\"\(number(shadow.blur / 2))\" flood-color=\"\(shadow.color.svg)\" flood-opacity=\"\(number(shadow.color.alpha))\"/></filter>")
                attributes += " filter=\"url(#\(filter))\""
            }
            if let clip = layer.clip {
                definitions.append("<clipPath id=\"clip\(index)\"><path d=\"\(pathData(clip))\"/></clipPath>")
                attributes += " clip-path=\"url(#clip\(index))\""
            }
            shapes.append("<path d=\"\(pathData(layer.path))\" \(attributes)/>")
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
          <title id="title">LLM Usage — LLM monogram (\(appearance.rawValue))</title>
          <desc>Vector paths, gradients and filter effects. No embedded raster images or external assets.</desc>
          <defs>\(definitions.joined(separator: "\n"))</defs>
          \(shapes.joined(separator: "\n"))
        </svg>
        """
    }
    private static func number(_ value: CGFloat) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    private static func pathData(_ path: CGPath) -> String {
        var result: [String] = []
        path.applyWithBlock { element in
            let item = element.pointee
            func pair(_ index: Int) -> String { "\(number(item.points[index].x)) \(number(item.points[index].y))" }
            switch item.type {
            case .moveToPoint: result.append("M \(pair(0))")
            case .addLineToPoint: result.append("L \(pair(0))")
            case .addQuadCurveToPoint: result.append("Q \(pair(0)) \(pair(1))")
            case .addCurveToPoint: result.append("C \(pair(0)) \(pair(1)) \(pair(2))")
            case .closeSubpath: result.append("Z")
            @unknown default: break
            }
        }
        return result.joined(separator: " ")
    }
}
