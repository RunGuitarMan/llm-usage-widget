import SwiftUI

struct ModelsView: View {
    @ObservedObject var store: UsageStore
    var snapshot: UsageSnapshot
    @State private var expanded: Set<String> = []
    @State private var showExplanation = false
    @State private var modelName = ""
    private var models: [ModelSummary] {
        snapshot.modelSummaries.sorted { $0.usage.cost == $1.usage.cost ? $0.id < $1.id : $0.usage.cost > $1.usage.cost }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Расходы по моделям")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(UsageFormat.cost(snapshot.totals)).font(.system(size: 44, weight: .semibold)).tracking(-1.5)
                        Text(L10n.text("Модели: \(models.count) · По убыванию стоимости")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showExplanation.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).help(L10n.text("Как учитываются модели"))
                        .popover(isPresented: $showExplanation) {
                            Text(L10n.text("Если ccusage не предоставил полную разбивку по моделям, смешанная сессия остаётся одной общей строкой. Так токены и стоимость не учитываются дважды."))
                                .font(.callout).padding(18).frame(width: 300)
                        }
                }
                modelSettings
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
                                        UsageBar(fraction: snapshot.totals.cost > 0 ? model.usage.cost / snapshot.totals.cost : 0,
                                                 color: .accentColor, height: 4).frame(maxWidth: 180)
                                    }
                                    Spacer(minLength: 6)
                                    Text(UsageFormat.cost(model.usage)).font(.system(size: 24, weight: .medium)).monospacedDigit()
                                }
                            }.disclosureGroupStyle(WholeRowDisclosureStyle(padding: 18))
                        }
                    }
                }
            }.padding(30).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
    }

    private var modelSettings: some View {
        DashboardSection {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("Учёт моделей")).font(.headline)
                Text(L10n.text("Выключите модель, чтобы исключить её токены и стоимость из итогов за все дни. Записи сессий сохраняются. Z.ai / GLM исключены по умолчанию."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.knownModels, id: \.self) { model in
                    Toggle(isOn: Binding(get: { store.modelExclusionPolicy.includes(model) }, set: {
                        store.setModelIncluded($0, model: model)
                    })) {
                        Text(model).font(.system(size: 12)).textSelection(.enabled)
                    }.toggleStyle(.switch).controlSize(.small)
                }
                HStack {
                    TextField(L10n.text("Точное имя модели"), text: $modelName)
                        .textFieldStyle(.roundedBorder).onSubmit(excludeModel)
                    Button(L10n.text("Исключить"), action: excludeModel)
                        .disabled(ModelExclusionPolicy.key(modelName).isEmpty)
                }
                Text(L10n.text("Если данные смешанной сессии нельзя разделить по моделям, она не включается в итоги, а сумма помечается как неполная."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private func excludeModel() {
        guard !ModelExclusionPolicy.key(modelName).isEmpty else { return }
        store.setModelIncluded(false, model: modelName)
        modelName = ""
    }
}
