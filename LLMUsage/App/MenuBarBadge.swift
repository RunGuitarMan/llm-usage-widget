import AppKit
import SwiftUI

/// A template image keeps the label at the native menu-bar text size.
/// The system supplies the selection background and adapts the ink to the wallpaper.
enum MenuBarBadge {
    static func image(usage: TokenUsage?, compact: Bool = false, day: UsageDay? = nil) -> NSImage {
        let amount = UsageFormat.menuBarCost(usage)
        let text = compact ? amount : "LLM  \(amount)"
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.black
        ])
        let measured = label.size()
        let size = NSSize(width: ceil(measured.width) + 2, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            label.draw(at: NSPoint(x: 1, y: (size.height - measured.height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel(usage, day: day)
        return image
    }

    static func accessibilityLabel(_ usage: TokenUsage?, day: UsageDay? = nil) -> String {
        guard let usage else { return L10n.text("LLM Usage, статистика загружается") }
        return ["LLM Usage", day?.label(), UsageFormat.cost(usage)].compactMap { $0 }.joined(separator: " · ")
    }
}

struct MenuBarUsageLabel: View {
    var usage: TokenUsage?
    var compact = false
    var body: some View {
        Image(nsImage: MenuBarBadge.image(usage: usage, compact: compact))
            .renderingMode(.template)
            .accessibilityLabel(MenuBarBadge.accessibilityLabel(usage))
            .help(usage.map { L10n.text("LLM Usage · \(UsageFormat.cost($0)) за сегодня · нажмите для подробностей") }
                  ?? L10n.text("LLM Usage · загружаем статистику"))
    }
}
