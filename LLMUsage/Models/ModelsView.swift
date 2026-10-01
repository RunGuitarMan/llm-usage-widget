import SwiftUI

struct ModelsView: View {
    @ObservedObject var store: UsageStore
    var snapshot: UsageSnapshot
    @State private var expanded: Set<String> = []
    @State private var showExplanation = false
    @State private var showExclusions = false
    private var models: [ModelSummary] {
        snapshot.reportedModelSummaries(applying: store.modelExclusionPolicy)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Учтённые расходы")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(UsageFormat.cost(snapshot.totals)).font(.system(size: 44, weight: .semibold))
                        Text(L10n.text("Модели: \(models.count) · По убыванию стоимости")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Исключённые модели: \(store.excludedModels.count)")) { showExclusions.toggle() }
                        .font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless)
                        .popover(isPresented: $showExclusions) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(L10n.text("Исключённые модели")).font(.headline)
                                    ModelExclusionControls(store: store)
                                }.padding(18)
                            }.frame(width: 400, height: 360)
                        }
                    Button { showExplanation.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).help(L10n.text("Как учитываются модели"))
                        .popover(isPresented: $showExplanation) {
                            Text(L10n.text("Если ccusage не предоставил полную разбивку по моделям, смешанная сессия остаётся одной общей строкой. Так токены и стоимость не учитываются дважды."))
                                .font(.callout).padding(18).frame(width: 300)
                        }
                }
                if models.isEmpty { EmptyUsageView() }
                else {
                    DashboardSection {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider().padding(.horizontal, 18) }
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(model.id) }, set: {
                                if $0 { expanded.insert(model.id) } else { expanded.remove(model.id) }
                            })) {
                                TokenUsageDetails(usage: model.usage).padding(.top, 18)
                                if model.usage.costIsIncomplete == true {
                                    Text(L10n.text("Часть данных для расчёта недоступна")).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                                }
                            } label: {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(model.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                        Text(L10n.text("Сессии: \(model.sessionCount) · \(UsageFormat.tokens(model.usage.total)) токенов"))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        if model.isExcluded {
                                            Label(L10n.text("Не учитывается в итогах"), systemImage: "minus.circle")
                                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                        } else {
                                            UsageBar(fraction: snapshot.totals.cost > 0 ? model.usage.cost / snapshot.totals.cost : 0,
                                                     color: .accentColor, height: 4).frame(maxWidth: 180)
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    Text(UsageFormat.cost(model.usage)).font(.system(size: 24, weight: .medium)).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                }
                            }.disclosureGroupStyle(WholeRowDisclosureStyle(padding: 18))
                        }
                    }
                }
            }.padding(30).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }

}

/// Shared with Settings, where exclusions remain accessible before a report loads.
struct ModelExclusionControls: View {
    @ObservedObject var store: UsageStore
    @State private var modelName = ""
    @State private var showIncluded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Исключённые модели не входят в суммы денег и токенов за все дни. Записи сессий сохраняются. Z.ai / GLM исключены по умолчанию."))
                .font(.caption).foregroundStyle(.secondary)
            if store.excludedModels.isEmpty {
                Text(L10n.text("Среди загруженных моделей нет исключённых."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.excludedModels, id: \.self) { model in
                HStack {
                    Text(model).textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button(L10n.text("Учитывать")) { store.setModelIncluded(true, model: model) }
                        .accessibilityLabel(L10n.text("Учитывать модель \(model)"))
                }.font(.system(size: 12))
            }
            HStack {
                TextField(L10n.text("Точное имя модели"), text: $modelName)
                    .textFieldStyle(.roundedBorder).onSubmit(excludeModel)
                Button(L10n.text("Исключить"), action: excludeModel)
                    .disabled(ModelExclusionPolicy.key(modelName).isEmpty)
            }
            let included = store.knownModels.filter { store.modelExclusionPolicy.includes($0) }
            if !included.isEmpty {
                DisclosureGroup(L10n.text("Выбрать из учитываемых моделей"), isExpanded: $showIncluded) {
                    VStack(spacing: 10) {
                        ForEach(included, id: \.self) { model in
                            HStack {
                                Text(model)
                                Spacer(minLength: 12)
                                Button(L10n.text("Исключить")) { store.setModelIncluded(false, model: model) }
                                    .accessibilityLabel(L10n.text("Исключить модель \(model)"))
                            }
                        }
                    }.font(.system(size: 12)).padding(.top, 8)
                }
            }
            Text(L10n.text("Если данные смешанной сессии нельзя разделить по моделям, она целиком исключается из итогов."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func excludeModel() {
        guard !ModelExclusionPolicy.key(modelName).isEmpty else { return }
        store.setModelIncluded(false, model: modelName)
        modelName = ""
    }
}
