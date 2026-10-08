import SwiftUI

/// All compact surfaces use the same summary and destination. The full list is
/// available in the app even when only one line fits in a widget or popover.
struct UsageProblemLabel: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
    var problems: [UsageProblem]
    var compact = false
    private var informational: Bool { problems.allSatisfy(\.isInformational) }
    private var label: String { informational ? strings.text("Частичный расчёт") : UsageHealth.summary(problems, language: interfaceLanguage) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: informational ? "info.circle" : "exclamationmark.triangle")
                .foregroundStyle(informational ? Color.secondary : Color.orange)
            if !compact { Text(label).lineLimit(1).truncationMode(.tail) }
            else if problems.count > 1 { Text(String(problems.count)).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageHealth.summary(problems, language: interfaceLanguage))
        .help(UsageHealth.summary(problems, language: interfaceLanguage) + ". " + strings.text("Подробнее"))
        #if MANUAL_REVIEW
        .background(ReviewHealthProbe(problems: problems))
        #endif
    }
}

struct UsageProblemLink: View {
    @Environment(\.usageLanguage) private var interfaceLanguage
    private var strings: UsageLocalizer { .init(language: interfaceLanguage) }
    var problems: [UsageProblem]
    var compact = false
    var body: some View {
        if let problem = problems.first {
            Link(destination: UsageRoute.problem(problem.reference).url) {
                UsageProblemLabel(problems: problems, compact: compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("usage-problem-link")
        }
    }
}
