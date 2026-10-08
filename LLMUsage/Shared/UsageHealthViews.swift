import SwiftUI

/// All compact surfaces use the same summary and destination. The full list is
/// available in the app even when only one line fits in a widget or popover.
struct UsageProblemLabel: View {
    var problems: [UsageProblem]
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            if !compact { Text(UsageHealth.summary(problems)).lineLimit(1).truncationMode(.tail) }
            else if problems.count > 1 { Text(String(problems.count)).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageHealth.summary(problems))
        .help(UsageHealth.summary(problems) + ". " + L10n.text("Подробнее"))
        #if MANUAL_REVIEW
        .background(ReviewHealthProbe(problems: problems))
        #endif
    }
}

struct UsageProblemLink: View {
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
