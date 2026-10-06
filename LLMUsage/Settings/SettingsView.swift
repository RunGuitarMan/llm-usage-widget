import SwiftUI
import ServiceManagement

struct UsageSettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var showStorage = false
    @State private var budgetText = ""
    @State private var budgetError = false
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    private var versionLabel: String {
        if Bundle.main.object(forInfoDictionaryKey: "UsageUpdateChannel") as? String == "release" {
            return L10n.text("LLM Usage \(appVersion) · Данные на этом Mac")
        }
        return L10n.text("LLM Usage \(appVersion) · Тестовая сборка · Данные на этом Mac")
    }

    var body: some View {
        Form {
            Section(L10n.text("Основные")) {
                Picker(L10n.text("Язык интерфейса"), selection: $store.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { language in Text(language.title).tag(language) }
                }
                LabeledContent(L10n.text("Период по умолчанию"), value: L10n.text("Сегодня"))
                Picker(L10n.text("Часовой пояс"), selection: $store.timezone) {
                    Text("UTC").tag("UTC")
                    if TimeZone.current.identifier != "UTC" {
                        Text(TimeZone.current.identifier).tag(TimeZone.current.identifier)
                    }
                }
                .onChange(of: store.timezone) { _, _ in Task { await store.selectPeriod() } }
                Toggle(L10n.text("Запускать при входе в систему"), isOn: Binding(get: { loginEnabled }, set: { setLogin($0) }))
                    .disabled(store.isDemo)
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
                Text(L10n.text("Приложение продолжает обновлять данные после закрытия окна. Управление доступно в строке меню."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Исключённые модели")) {
                ModelExclusionControls(store: store)
            }
            Section(L10n.text("Обновление данных")) {
                Picker(L10n.text("Способ обновления"), selection: $store.updateMode) {
                    ForEach(UsageUpdateMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.menu)
                .disabled(store.isDemo)
                .onChange(of: store.updateMode) { _, _ in Task { await store.selectPeriod() } }
                Text(store.updateMode == .claudeOnly
                     ? L10n.text("Статистика только Claude Code.")
                     : L10n.text("Claude Code, Codex и другие локальные агенты. Обновление может занимать больше времени."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L10n.text("Быстрый режим"), selection: Binding(
                    get: { store.refreshIntervals.fastSeconds },
                    set: { store.setRefreshIntervals(fastSeconds: $0) })) {
                    ForEach(RefreshIntervals.fastOptions, id: \.self) { Text(L10n.text("\($0) сек")).tag($0) }
                }
                Picker(L10n.text("Средний режим"), selection: Binding(
                    get: { store.refreshIntervals.mediumMinutes },
                    set: { store.setRefreshIntervals(mediumMinutes: $0) })) {
                    ForEach(RefreshIntervals.mediumOptions, id: \.self) { value in
                        Text(L10n.text("\(value) мин")).tag(value)
                            .disabled(value >= store.refreshIntervals.slowMinutes)
                    }
                }
                Picker(L10n.text("Медленный режим"), selection: Binding(
                    get: { store.refreshIntervals.slowMinutes },
                    set: { store.setRefreshIntervals(slowMinutes: $0) })) {
                    ForEach(RefreshIntervals.slowOptions, id: \.self) { value in
                        Text(L10n.text("\(value) мин")).tag(value)
                            .disabled(value <= store.refreshIntervals.mediumMinutes)
                    }
                }
                LabeledContent(L10n.text("Текущий режим"), value: store.refreshMode.title)
                Text(L10n.text("Изменение суммы при ручном или автоматическом обновлении включает быстрый режим. Минута без изменений — средний режим, ещё 3 минуты — медленный. Запуск начинается с медленного режима."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("Если режим не изменился, ручное обновление сохраняет расписание. В быстром режиме пропускается ближайшее автообновление."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Виджеты")) {
                LabeledContent(L10n.text("Сводка"), value: L10n.text("Стоимость, токены и сессии"))
                LabeledContent(L10n.text("Сессии"), value: L10n.text("Рейтинг по стоимости"))
                LabeledContent(L10n.text("Динамика"), value: L10n.text("Расходы за 7 дней"))
                Text(L10n.text("Откройте галерею виджетов macOS и найдите LLM Usage. Каждый вариант доступен в трёх размерах; можно добавить несколько одновременно."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("История загружается в фоне. Пропущенные дни отмечены прочерком, нулевые расходы — кружком. Сегодняшний день ещё не завершён."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Дневной бюджет")) {
                Toggle(L10n.text("Показывать бюджет"), isOn: $store.budgetEnabled)
                if store.budgetEnabled {
                    HStack {
                        TextField(L10n.text("Сумма в USD"), text: $budgetText).frame(maxWidth: 220)
                            .onSubmit(applyBudget)
                        Button(L10n.text("Применить"), action: applyBudget)
                    }
                    if budgetError {
                        Text(L10n.text("Введите сумму больше нуля.")).font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(L10n.text("Ориентир для расходов за день в выбранном часовом поясе. Бюджет не останавливает сессии. При неполных ценах показывается только учтённая стоимость."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Строка меню")) {
                Picker(L10n.text("Содержимое меню"), selection: $store.menuContent) {
                    ForEach(MenuContentMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Toggle(L10n.text("Компактный вид без LLM"), isOn: $store.compactMenuBar)
                HStack {
                    Text(L10n.text("Предпросмотр")).foregroundStyle(.secondary)
                    Spacer()
                    MenuBarUsageLabel(usage: store.todaySnapshot?.totals ?? TokenUsage(cost: 23.36),
                                      compact: store.compactMenuBar)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(L10n.text("Скрывает надпись LLM, оставляя сумму за сегодня. Изменение применяется сразу."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            AppMaintenanceSettings(updates: .shared, disabled: store.isDemo)
            Section {
                DisclosureGroup(L10n.text("Хранилище и диагностика"), isExpanded: $showStorage) {
                    LabeledContent(L10n.text("Последняя попытка"), value: store.lastAttempt.map { UsageFormat.date($0, includeTime: true) } ?? "—")
                    LabeledContent(L10n.text("Последнее успешное обновление"), value: store.todaySnapshot.map { UsageFormat.date($0.generatedAt, includeTime: true) } ?? "—")
                    if SharedConfiguration.usesLocalWidgetStorage {
                        LabeledContent(L10n.text("Данные виджета"), value: L10n.text("Локальные снимки статистики"))
                    } else {
                        LabeledContent("App Group", value: SharedConfiguration.appGroup).textSelection(.enabled)
                    }
                    if let error = store.storageError {
                        Label(error.errorDescription ?? L10n.text("Ошибка хранилища"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error.recovery).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(L10n.text("Обновить сейчас")) { Task { await store.refresh() } }.disabled(store.isRefreshing || store.isDemo)
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                    }
                    Text(L10n.text("macOS сама планирует обновления WidgetKit. Виджет может перерисовываться позже, чем приложение получает данные."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.diagnosticError ?? store.error ?? store.storageError {
                Section {
                    DisclosureGroup(L10n.text("Технические подробности")) {
                        Text(error.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Section {
                HStack {
                    UsageBrand(compact: true)
                    Spacer()
                    Text(versionLabel).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("app-version")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            updateLoginStatus()
            budgetText = UsageFormat.decimal(store.budgetAmount)
            showStorage = store.storageError != nil
        }
        .onChange(of: store.storageError?.errorDescription) { _, error in if error != nil { showStorage = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in updateLoginStatus() }
    }

    private func applyBudget() {
        let cleaned = budgetText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(cleaned), store.setBudgetAmount(amount) else { budgetError = true; return }
        budgetError = false
        budgetText = UsageFormat.decimal(store.budgetAmount)
    }

    private func setLogin(_ enabled: Bool) {
        if store.isManualReview { loginEnabled = enabled; return }
        guard !store.isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                loginMessage = L10n.text("Разрешите запуск в System Settings → General → Login Items.")
                SMAppService.openSystemSettingsLoginItems()
            } else { loginMessage = nil }
        } catch {
            loginMessage = L10n.text("Не удалось изменить автозапуск. Переместите подписанное приложение в Applications и проверьте Login Items.")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }

    private func updateLoginStatus() {
        if store.isManualReview { return }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        if status == .requiresApproval { loginMessage = L10n.text("Разрешите запуск в System Settings → General → Login Items.") }
        else if status == .enabled { loginMessage = nil }
    }
}

struct SettingsPreviews: PreviewProvider {
    static var previews: some View {
        UsageSettingsView(store: UsageStore(demo: true)).frame(width: 820, height: 680).previewDisplayName("Settings")
        EmptyUsageView(title: L10n.text("ccusage не найден"), message: UsageError.missingExecutable.recovery, symbol: "terminal")
            .frame(width: 820, height: 580).previewDisplayName("CLI Missing")
    }
}
