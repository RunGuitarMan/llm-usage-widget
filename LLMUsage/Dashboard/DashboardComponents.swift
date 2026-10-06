import SwiftUI
import AppKit

struct DashboardSidebarLabel: View {
    var title: String
    var symbol: String
    var isSelected: Bool
    @Environment(\.appearsActive) private var appearsActive

    private var foreground: Color {
        guard appearsActive else { return .secondary }
        return isSelected ? .accentColor : .primary
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16)
            Text(title)
        }
        .fontWeight(isSelected ? .medium : .regular)
        .foregroundStyle(foreground)
        .accessibilityElement(children: .combine)
        .onChange(of: appearsActive, initial: true) { _, active in
            if let review = ManualReviewController.active {
                review.observedSidebarAppearance[symbol] = active
            }
        }
    }
}

struct DashboardSidebarSelection: View {
    var isSelected: Bool
    var horizontalInset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.appearsActive) private var appearsActive

    private var opacity: Double {
        if contrast == .increased { return colorScheme == .dark ? 0.24 : 0.16 }
        if colorScheme == .dark { return appearsActive ? 0.10 : 0.07 }
        return appearsActive ? 0.055 : 0.04
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.primary.opacity(opacity) : .clear)
            .padding(.horizontal, horizontalInset)
            .accessibilityHidden(true)
    }
}

struct DashboardSidebarSourceLabel: View {
    var id: String
    var name: String
    var count: Int
    var isSelected: Bool
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 8) {
            if id.isEmpty { Image(systemName: "square.stack.3d.up").frame(width: 14) }
            else { Circle().fill(appearsActive ? UsageSource.color(id) : .secondary).frame(width: 6, height: 6).frame(width: 14) }
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
            if isSelected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            else { Text(String(count)).font(.caption).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 12))
        .foregroundStyle(appearsActive && isSelected ? Color.primary : Color.secondary)
        .padding(.vertical, 3).contentShape(Rectangle())
    }
}

/// Keep List's selection, keyboard navigation and accessibility, but draw the
/// neutral Finder-style highlight instead of AppKit's accent-filled selection.
struct DashboardSidebarSelectionBridge: NSViewRepresentable {
    final class Attachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppressNativeHighlight()
        }

        func suppressNativeHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let row = view as? NSTableRowView { row.selectionHighlightStyle = .none }
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    break
                }
                ancestor = view.superview
            }
        }
    }

    func makeNSView(context: Context) -> Attachment { Attachment() }
    func updateNSView(_ view: Attachment, context: Context) { view.suppressNativeHighlight() }
}

/// Standard content material; navigation and controls use the system's separate glass layer.
struct DashboardBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct DashboardSection<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A disclosure header is one keyboard-accessible button, including its label and empty row space.
struct WholeRowDisclosureStyle: DisclosureGroupStyle {
    var padding: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 10).accessibilityHidden(true)
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(padding).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? L10n.text("Развёрнуто") : L10n.text("Свёрнуто"))
            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, padding)
                    .padding(.bottom, padding)
            }
        }
    }
}

struct TokenUsageDetails: View {
    var usage: TokenUsage
    var body: some View {
        VStack(spacing: 14) {
            TokenDistribution(usage: usage)
            ForEach(usage.categories) { category in
                HStack(spacing: 8) {
                    Circle().fill(category.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(category.title).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(UsageFormat.exact(usage.value(for: category))).monospacedDigit()
                        Text(UsageFormat.menuBarPercent(count: usage.value(for: category), total: usage.total))
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }.font(.system(size: 12)).accessibilityElement(children: .combine)
            }
        }
    }
}

struct TokenUsageGrid: View {
    var usage: TokenUsage
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TokenDistribution(usage: usage, height: 10)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(usage.categories) { category in
                        metric(category).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 20) {
                    ForEach(usage.categories) { metric($0) }
                }
            }
        }
    }

    private func metric(_ category: TokenCategory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(category.color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(category.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(UsageFormat.tokens(usage.value(for: category)))
                .font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(UsageFormat.menuBarPercent(count: usage.value(for: category), total: usage.total))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .help(UsageFormat.exact(usage.value(for: category)) + L10n.text(" токенов"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("\(category.title): \(UsageFormat.exact(usage.value(for: category))) токенов"))
    }
}

/// Browsing months is local to the calendar; only selecting/confirming a day
/// invokes the callback. The footer also permits reselecting the initial day.
struct UsageDatePopover: View {
    @State private var selection: Date
    @State private var visibleMonth: Date
    var timezone: String
    var onSelect: (Date) -> Void
    var onCancel: () -> Void

    init(date: Date, timezone: String, onSelect: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        _selection = State(initialValue: date)
        _visibleMonth = State(initialValue: date)
        self.timezone = timezone
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    private var month: UsageCalendarMonth {
        UsageCalendarMonth(containing: visibleMonth, timezone: timezone, locale: L10n.locale)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = month.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter.string(from: month.start).localizedCapitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(monthTitle).font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                monthButton(-1, symbol: "chevron.left", title: "Предыдущий месяц")
                monthButton(1, symbol: "chevron.right", title: "Следующий месяц")
                    .disabled(!month.isSelectable(month.moving(1)))
            }
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Array(month.weekdays.enumerated()), id: \.offset) { _, title in
                        Text(title).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary).frame(width: 32, height: 22)
                    }
                }.accessibilityHidden(true)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 7), spacing: 4) {
                    ForEach(month.days, id: \.self) { date in dayButton(date) }
                }
            }
            Divider()
            HStack {
                Button(L10n.text("Сегодня")) { onSelect(month.calendar.startOfDay(for: Date())) }
                    .buttonStyle(.borderless)
                Spacer()
                Button(L10n.text("Готово")) { onSelect(selection) }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 284)
            .onExitCommand(perform: onCancel)
    }

    private func monthButton(_ offset: Int, symbol: String, title: LocalizedPhrase) -> some View {
        Button { visibleMonth = month.moving(offset) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                .contentShape(Circle())
        }.buttonStyle(.plain)
            .background(Color.primary.opacity(0.045), in: Circle())
            .accessibilityLabel(L10n.text(title)).help(L10n.text(title))
    }

    private func dayButton(_ date: Date) -> some View {
        let selected = month.calendar.isDate(date, inSameDayAs: selection)
        let today = month.calendar.isDateInToday(date)
        return Button {
            selection = date
            onSelect(date)
        } label: {
            Text(String(month.calendar.component(.day, from: date)))
                .font(.system(size: 12, weight: selected || today ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(selected ? Color.white : month.contains(date) ? Color.primary : Color.secondary)
                .frame(width: 32, height: 32)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(today && !selected ? Color.accentColor.opacity(0.6) : .clear) }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(!month.isSelectable(date))
            .opacity(month.isSelectable(date) ? 1 : 0.3)
            .accessibilityLabel(UsageFormat.date(date, timezone: timezone))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bundled SVGs stay vector at every display scale and follow the system label color.
struct ProviderLogo: View {
    var provider: ModelProvider
    var helpText: String? = nil
    static let cornerRadius: CGFloat = 8

    static let images: [ModelProvider: NSImage] = {
        var result: [ModelProvider: NSImage] = [:]
        for provider in ModelProvider.brandedCases {
            if let url = Bundle.main.url(forResource: provider.rawValue, withExtension: "svg", subdirectory: "Providers"),
               let image = NSImage(contentsOf: url), image.isValid {
                image.isTemplate = true
                result[provider] = image
            }
        }
        return result
    }()

    var body: some View {
        Group {
            if let image = Self.images[provider] {
                Image(nsImage: image).resizable().scaledToFit().padding(5)
            } else {
                Image(systemName: provider == .mixed ? "square.stack.3d.up" : "cpu")
                    .font(.system(size: 17, weight: .regular))
            }
        }
        .foregroundStyle(.primary.opacity(0.8))
        .frame(width: 30, height: 30)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .help(helpText ?? L10n.text("Провайдер модели: \(provider.title)"))
        .accessibilityHidden(true)
    }
}

/// Mixed sessions keep their brands in a compact, leading-to-trailing stack.
struct ProviderLogos: View {
    var models: [String]
    private let overlap: CGFloat = 8
    private var providers: [ModelProvider] { ModelProvider.logos(models: models) }
    private var description: String { providers.map(\.title).joined(separator: ", ") }

    var body: some View {
        HStack(spacing: providers.count > 1 ? -overlap : 0) {
            ForEach(Array(providers.enumerated()), id: \.element.rawValue) { index, provider in
                ProviderLogo(provider: provider, helpText: description)
                    .mask {
                        if index > 0 {
                            StackCutout(overlap: overlap).fill(style: FillStyle(eoFill: true))
                        } else { Rectangle() }
                    }
                    .zIndex(Double(providers.count - index))
            }
        }
        .background(ReviewProviderProbe(models: models, providers: providers, label: description))
        .help(description).accessibilityElement(children: .ignore).accessibilityLabel(description)
    }

    /// Cut away the preceding tile and a narrow gap. Every visible tile retains
    /// the same translucent fill as a solo logo, including over selected rows.
    private struct StackCutout: Shape {
        var overlap: CGFloat
        private let gap: CGFloat = 1.5

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            let preceding = rect.offsetBy(dx: -(rect.width - overlap), dy: 0).insetBy(dx: -gap, dy: -gap)
            path.addPath(RoundedRectangle(cornerRadius: ProviderLogo.cornerRadius + gap).path(in: preceding))
            return path
        }
    }
}

struct SessionSummaryRow: View {
    var session: UsageSession
    var timezone: String
    var selected: Bool
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var tokenDescription: String {
        ([L10n.text("Состав токенов")] + session.usage.categories.map { category in
            L10n.text("\(category.title): \(UsageFormat.exact(session.usage.value(for: category))) токенов")
        }).joined(separator: "\n")
    }

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                row(compact: false).frame(minWidth: 540)
                row(compact: true)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(contrast == .increased ? 0.18 : 0.09)
                        : hovered ? Color.primary.opacity(0.04) : .clear)
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityLabel(L10n.text("\(session.sourceLabel), \(session.shortID), \(UsageFormat.cost(session.usage)), \(UsageFormat.tokens(session.usage.total)) токенов. Подробности"))
        .accessibilityValue(session.modelLabel + ". " + ModelProvider.logos(models: session.models + session.modelBreakdowns.map(\.id))
            .map(\.title).joined(separator: ", ") + ". " + tokenDescription)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProviderLogos(models: session.models + session.modelBreakdowns.map(\.id))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.modelLabel).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            .help(session.modelLabel)
                        Text(session.sourceLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .help(UsageFormat.activity(session, timezone: timezone))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if compact { tokenSummary.frame(maxWidth: 160).padding(.leading, 42) }
            }
            .frame(minWidth: compact ? 112 : 182, maxWidth: .infinity, alignment: .leading)
            if !compact { tokenSummary.frame(width: 140).padding(.trailing, 8) }
            Text(UsageFormat.cost(session.usage)).font(.system(size: 18, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
                .frame(width: compact ? 96 : 112, alignment: .trailing)
                .help(UsageFormat.cost(session.usage))
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary).frame(width: 9).accessibilityHidden(true)
        }
    }

    private var tokenSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("\(UsageFormat.tokens(session.usage.total)) токенов"))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            TokenDistribution(usage: session.usage, height: 5)
        }.help(tokenDescription)
    }
}
