import SwiftUI

struct UsageProblemBanner: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        let problems = store.problems(for: store.selectedDay, includeHidden: false).filter { !$0.isInformational }
        if let first = problems.first {
            HStack(spacing: 8) {
            Button { store.presentedProblem = first.reference } label: {
                HStack(spacing: 10) {
                    UsageProblemLabel(problems: problems)
                    Spacer(minLength: 8)
                    Text(L10n.text("Подробнее"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("usage-problem-banner")
            .background { if store.isManualReview { ReviewHealthProbe(problems: problems) } }
            Button {
                for problem in problems { store.hideProblem(problem) }
            } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).help(L10n.text("Скрыть предупреждение"))
                .accessibilityIdentifier("usage-problem-banner-hide")
            }.padding(.horizontal, 28)
                .background(Color.orange.opacity(0.06), ignoresSafeAreaEdges: [])
        }
    }
}

struct UsageProblemsView: View {
    @ObservedObject var store: UsageStore
    var requested: UsageProblemReference
    @State private var restored = false
    @State private var selection: UsageProblemReference?
    @Environment(\.dismiss) private var dismiss

    private var active: UsageProblemReference { selection ?? requested }
    private var problems: [UsageProblem] { store.problems(for: active.day ?? store.selectedDay) }
    private var selected: UsageProblem? { problems.first { $0.reference == active } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Состояние данных")).font(.title2.weight(.semibold))
                Spacer()
                if let selected {
                    Button(L10n.text("Скрыть")) { store.hideProblem(selected); dismiss() }
                        .help(L10n.text("Скрыть предупреждение"))
                        .accessibilityIdentifier("usage-problem-hide")
                        .background { if store.isManualReview { ReviewHealthControlProbe(name: "hide") } }
                }
                Button(L10n.text("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("usage-problems-close")
                    .background { if store.isManualReview { ReviewHealthControlProbe(name: "close") } }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let selected { problemDetails(selected) }
                    else if !restored {
                        ProgressView(L10n.text("Проверяем состояние данных…"))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(active.kind.title, systemImage: "info.circle").font(.headline)
                            Text(active.kind == .storage
                                ? L10n.text("В приложении эта ошибка сейчас не обнаружена. Если виджет по-прежнему сообщает о ней, проверьте хранилище: доступ расширения может отличаться.")
                                : L10n.text("Эта проблема больше не обнаружена в текущих данных. Виджет мог показывать предыдущий результат; macOS обновит его по своему расписанию."))
                                .foregroundStyle(.secondary)
                            if active.kind == .storage { settingsButton(storage: true) }
                        }.accessibilityIdentifier("usage-problem-resolved")
                            .background { if store.isManualReview { ReviewHealthControlProbe(name: "resolved") } }
                    }
                    recoveryStatus
                    let others = problems.filter { $0.reference != active }
                    if !others.isEmpty {
                        Divider()
                        Text(L10n.text("Другие проблемы")).font(.headline)
                        ForEach(others) { problem in
                            Button { selection = problem.reference } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(problem.title)
                                        Text(problem.scope).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    let otherDates = store.problems().filter { $0.reference.day != nil && $0.reference.day != (active.day ?? store.selectedDay) }
                    if !otherDates.isEmpty {
                        DisclosureGroup(L10n.text("Другие даты")) {
                            ForEach(otherDates) { problem in
                                Button { selection = problem.reference } label: {
                                    Text(problem.scope + " · " + problem.title).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).padding(.vertical, 4)
                                    .accessibilityIdentifier("usage-problem-date-" + problem.reference.id)
                            }
                        }
                        Button(L10n.text("Пересчитать проблемные дни")) { Task { await store.retryAllProblems() } }
                            .disabled(store.isRefreshing || store.isRetryingProblem || store.isDemo)
                            .accessibilityIdentifier("usage-problems-retry-all")
                            .background { if store.isManualReview { ReviewHealthControlProbe(name: "retry-all") } }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 520)
        .accessibilityIdentifier("usage-problems-sheet")
        .task { await store.restoreSavedData(); restored = true }
    }

    private func problemDetails(_ problem: UsageProblem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(problem.title, systemImage: problem.isInformational ? "info.circle" : "exclamationmark.triangle").font(.headline)
            Text(problem.scope).font(.caption).foregroundStyle(.secondary)
            Text(problem.explanation).fixedSize(horizontal: false, vertical: true)
            ForEach(problem.costReasons ?? [], id: \.rawValue) { reason in
                Text(reason.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if let date = problem.lastSuccess {
                    GridRow {
                        Text(L10n.text(problem.reference.kind == .cost ? "Последний расчёт" : "Последнее успешное обновление"))
                        Text(UsageFormat.date(date, timezone: problem.reference.day?.timezone ?? store.timezone, includeTime: true))
                    }
                }
                if let date = problem.attemptedAt, date != problem.lastSuccess {
                    GridRow {
                        Text(L10n.text("Последняя попытка"))
                        Text(UsageFormat.date(date, timezone: problem.reference.day?.timezone ?? store.timezone, includeTime: true))
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
            if !problem.models.isEmpty {
                Text(L10n.text("Затронутые модели: \(problem.models.joined(separator: ", "))"))
                    .font(.callout).textSelection(.enabled)
            }
            if !problem.missingDays.isEmpty {
                Text(problem.missingDays.map { UsageFormat.date($0.date, timezone: $0.timezone) }.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(store.isRefreshing || store.isRetryingProblem ? L10n.text("Обновляем…") : L10n.text("Обновить сейчас")) {
                    Task { await store.retryProblem(problem.reference) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRefreshing || store.isRetryingProblem || store.isDemo)
                .accessibilityIdentifier("usage-problem-retry")
                .background { if store.isManualReview { ReviewHealthControlProbe(name: "retry") } }
                if problem.reference.kind == .cost, let day = problem.reference.day {
                    Button(L10n.text("Открыть сессии")) {
                        dismiss()
                        store.navigate(.datedSessions(day))
                    }
                } else if problem.reference.kind == .storage || problem.reference.kind == .refresh {
                    settingsButton(storage: problem.reference.kind == .storage)
                }
            }
            if let details = problem.details, !details.isEmpty {
                DisclosureGroup(L10n.text("Технические подробности")) {
                    Text(details).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.accessibilityIdentifier("usage-problem-details")
            .background { if store.isManualReview { ReviewHealthControlProbe(name: "details") } }
    }

    @ViewBuilder private var recoveryStatus: some View {
        if store.isRetryingProblem {
            HStack {
                ProgressView().controlSize(.small)
                Text(L10n.text("Пересчёт"))
                Text("\(store.recoveryCompleted) / \(store.recoveryTotal)").monospacedDigit()
            }.accessibilityIdentifier("usage-recovery-progress")
        } else if let result = store.recoveryResult, result.days.contains(active.day ?? store.selectedDay) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Пересчёт завершён")).font(.headline)
                Text(recoverySummary(result))
                if result.incomplete > 0 {
                    Text(L10n.text("Доступные данные пересчитаны. Оставшиеся ограничения описаны выше; повтор без новых исходных данных может дать тот же результат."))
                }
                Text(UsageFormat.date(result.completedAt, timezone: store.timezone, includeTime: true))
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("usage-recovery-result")
                .background { if store.isManualReview { ReviewHealthControlProbe(name: "result") } }
        }
    }

    private func recoverySummary(_ result: UsageRecoveryResult) -> String {
        ["\(L10n.text("Рассчитано полностью")): \(result.repaired)",
         "\(L10n.text("Частичный расчёт")): \(result.incomplete)",
         "\(L10n.text("Не удалось обновить")): \(result.failed)"].joined(separator: " · ")
    }

    private func settingsButton(storage: Bool) -> some View {
        Button(storage ? L10n.text("Хранилище и диагностика") : L10n.text("Компонент расчёта")) {
            dismiss()
            store.showStorageSettings = storage
            store.navigate(.settings)
        }.accessibilityIdentifier("usage-problem-settings")
    }
}
