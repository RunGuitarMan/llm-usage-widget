import SwiftUI

enum UsageStyle {
    static let orange = Color(red: 0.91, green: 0.47, blue: 0.29)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let stroke = Color.primary.opacity(0.065)
}

extension UsageSource {
    static func color(_ id: String) -> Color {
        switch id {
        case "claude": return UsageStyle.orange
        case "codex": return .indigo
        case "gemini": return .blue
        case "opencode": return .teal
        default: return .secondary
        }
    }
}

struct SourceBadge: View {
    var source: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(UsageSource.color(source)).frame(width: 6, height: 6)
            Text(UsageSource.label(source)).font(.caption.weight(.medium)).lineLimit(1)
        }.foregroundStyle(.secondary)
    }
}

extension TokenCategory {
    var color: Color {
        switch self {
        case .input: return Color(nsColor: .systemBlue).opacity(0.85)
        case .output: return Color(nsColor: .systemPurple).opacity(0.78)
        case .cacheCreate: return Color(nsColor: .systemOrange).opacity(0.82)
        case .cacheRead: return Color(nsColor: .systemGreen).opacity(0.78)
        case .additional: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// The same proportional amount anchors the popover and every widget family.
struct UsageAmount: View {
    var usage: TokenUsage
    var size: CGFloat = 48
    var body: some View {
        Text(UsageFormat.cost(usage))
            .font(.system(size: size, weight: .semibold)).tracking(-size * 0.035)
            .lineLimit(1).minimumScaleFactor(0.4)
            .frame(height: size * 1.16, alignment: .leading)
            .accessibilityLabel(L10n.text("Расходы: \(UsageFormat.cost(usage))\(usage.costIsIncomplete == true ? L10n.text(", стоимость неполная") : "")"))
    }
}

struct UsageDayCaption: View {
    var day: UsageDay
    var now = Date()
    var body: some View {
        Text(day.isToday(now: now) ? L10n.text("Сегодня") : UsageFormat.date(day.date, timezone: day.timezone))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
            .help(day.label())
    }
}

/// Vector artwork redrawn from the supplied reference, shared with the app icon.
struct LLMMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 28
    var body: some View {
        Canvas { context, dimensions in
            context.withCGContext { graphics in
                BrandGeometry.draw(in: CGRect(origin: .zero, size: dimensions), context: graphics, compact: true,
                                   appearance: colorScheme == .dark ? .dark : .light)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct UsageBrand: View {
    var subtitle: String? = nil
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            LLMMark(size: compact ? 24 : 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("LLM Usage").font(.system(size: compact ? 13 : 16, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary) }
            }
        }
    }
}

struct UsageBar: View {
    var fraction: Double
    var color: Color = .blue
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.055))
                Capsule().fill(color.opacity(0.82))
                    .frame(width: max(fraction > 0 ? 2 : 0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct Surface<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding)
            .background(UsageStyle.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(UsageStyle.stroke, lineWidth: 1))
    }
}

struct TokenBreakdown: View {
    var usage: TokenUsage
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 12 : 24) {
            ForEach(usage.categories) { category in
                VStack(alignment: .leading, spacing: 7) {
                    Text(compact ? compactTitle(category) : category.title)
                        .font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Text(compact ? UsageFormat.tokens(usage.value(for: category)) : UsageFormat.exact(usage.value(for: category)))
                        .font(.system(size: compact ? 14 : 17, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                    UsageBar(fraction: Double(usage.value(for: category)) / Double(max(usage.total, 1)), color: category.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("\(category.title): \(UsageFormat.exact(usage.value(for: category))) токенов"))
            }
        }
    }
    private func compactTitle(_ category: TokenCategory) -> String {
        switch category {
        case .cacheCreate: return "Create"
        case .cacheRead: return "Read"
        case .additional: return "Other"
        default: return category.title
        }
    }
}

struct EmptyUsageView: View {
    var title = L10n.text("Пока нет сессий")
    var message = L10n.text("Статистика появится после работы в Claude Code, Codex или другом агенте, поддерживаемом ccusage.")
    var symbol = "chart.bar.xaxis"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 54)
    }
}

struct TokenDistribution: View {
    var usage: TokenUsage
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(usage.categories.filter { usage.value(for: $0) > 0 }) { category in
                    Rectangle().fill(category.color)
                        .frame(width: segmentWidth(category, width: geometry.size.width))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05)).clipShape(Capsule())
        }.frame(height: height).accessibilityHidden(true)
    }

    private func segmentWidth(_ category: TokenCategory, width: CGFloat) -> CGFloat {
        let visible = usage.categories.filter { usage.value(for: $0) > 0 }
        let available = max(0, width - CGFloat(max(visible.count - 1, 0)))
        guard usage.total > 0, available > 0 else { return 0 }
        // A hairline keeps nonzero categories visible; labels retain the exact values.
        let minimum = min(1, available / CGFloat(max(visible.count, 1)))
        let weights = visible.map { max(minimum, available * CGFloat(usage.value(for: $0)) / CGFloat(usage.total)) }
        guard let index = visible.firstIndex(of: category) else { return 0 }
        return weights[index] / weights.reduce(0, +) * available
    }
}
