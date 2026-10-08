import SwiftUI

struct UsageProblemBanner: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        let problems = store.problems()
        if let first = problems.first {
            Button { store.presentedProblem = first.reference } label: {
                HStack(spacing: 10) {
                    UsageProblemLabel(problems: problems)
                    Spacer(minLength: 8)
                    Text(L10n.text("Подробнее"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption).padding(.horizontal, 28).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.orange.opacity(0.06), ignoresSafeAreaEdges: [])
            .accessibilityIdentifier("usage-problem-banner")
        }
    }
}

struct UsageProblemsView: View {
    @ObservedObject var store: UsageStore
    var requested: UsageProblemReference
    @State private var restored = false
    @Environment(\.dismiss) private var dismiss

    private var problems: [UsageProblem] { store.problems() }
    private var selected: UsageProblem? { problems.first { $0.reference == requested } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Состояние данных")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("usage-problems-close")
                    #if MANUAL_REVIEW
                    .background(ReviewHealthControlProbe(name: "close"))
                    #endif
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let selected { problemDetails(selected) }
                    else if !restored {
                        ProgressView(L10n.text("Проверяем состояние данных…"))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(requested.kind.title, systemImage: "info.circle").font(.headline)
                            Text(requested.kind == .storage
                                ? L10n.text("В приложении эта ошибка сейчас не обнаружена. Если виджет по-прежнему сообщает о ней, проверьте хранилище: доступ расширения может отличаться.")
                                : L10n.text("Эта проблема больше не обнаружена в текущих данных. Виджет мог показывать предыдущий результат; macOS обновит его по своему расписанию."))
                                .foregroundStyle(.secondary)
                            if requested.kind == .storage { settingsButton(storage: true) }
                        }.accessibilityIdentifier("usage-problem-resolved")
                            #if MANUAL_REVIEW
                            .background(ReviewHealthControlProbe(name: "resolved"))
                            #endif
                    }
                    let others = problems.filter { $0.reference != requested }
                    if !others.isEmpty {
                        Divider()
                        Text(L10n.text("Другие проблемы")).font(.headline)
                        ForEach(others) { problem in
                            Button { store.presentedProblem = problem.reference } label: {
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
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 520)
        .accessibilityIdentifier("usage-problems-sheet")
        .task { await store.restoreSavedData(); restored = true }
    }

    private func problemDetails(_ problem: UsageProblem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(problem.title, systemImage: "exclamationmark.triangle").font(.headline)
            Text(problem.scope).font(.caption).foregroundStyle(.secondary)
            Text(problem.explanation).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if let date = problem.lastSuccess {
                    GridRow {
                        Text(L10n.text("Последнее успешное обновление"))
                        Text(UsageFormat.date(date, timezone: problem.reference.day?.timezone ?? store.timezone, includeTime: true))
                    }
                }
                if let date = problem.attemptedAt {
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
                #if MANUAL_REVIEW
                .background(ReviewHealthControlProbe(name: "retry"))
                #endif
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
            #if MANUAL_REVIEW
            .background(ReviewHealthControlProbe(name: "details"))
            #endif
    }

    private func settingsButton(storage: Bool) -> some View {
        Button(storage ? L10n.text("Хранилище и диагностика") : L10n.text("Компонент расчёта")) {
            dismiss()
            store.showStorageSettings = storage
            store.navigate(.settings)
        }.accessibilityIdentifier("usage-problem-settings")
    }
}
