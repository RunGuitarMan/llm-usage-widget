import SwiftUI

struct AppMaintenanceSettings: View {
    @ObservedObject var updates: AppUpdateCoordinator
    var disabled = false

    var body: some View {
        Section(L10n.text("Компонент расчёта")) {
            LabeledContent("ccusage", value: CCUsageManifest.bundled?.version ?? "—")
            Text(L10n.text("Проверенная версия входит в приложение и обновляется вместе с ним. Node.js и npm не нужны."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.text("Использовать встроенный ccusage"), isOn: Binding(
                get: { updates.enabled }, set: { enabled in
                    if enabled { updates.presentsSetup = true } else { updates.deactivate() }
                }))
                .disabled(disabled || updates.phase == .installing)
            Text(L10n.text("Статистика обрабатывается на этом Mac. ccusage проверяет тарифы в интернете; если источник недоступен, использует встроенные цены. Стоимость — оценка, а не счёт за подписку."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L10n.text("Обновления приложения")) {
            Toggle(L10n.text("Проверять обновления автоматически"), isOn: $updates.preferences.checksAutomatically)
            Picker(L10n.text("При появлении новой версии"), selection: $updates.preferences.mode) {
                ForEach(AppUpdateMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Text(L10n.text("Разрешение распространяется на приложение и встроенный ccusage. Перед автоматическим перезапуском можно отложить установку."))
                .font(.caption).foregroundStyle(.secondary)
            AppUpdateStatus(updates: updates)
            Button(L10n.text("Проверить обновления…")) { updates.check() }
                .disabled(!updates.enabled || !updates.updatesSupported || updates.busy)
            if !updates.updatesSupported {
                Text(L10n.text("Автообновления доступны в релизах с GitHub."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(disabled || updates.phase == .installing)
    }
}

struct AppUpdateStatus: View {
    @ObservedObject var updates: AppUpdateCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updates.phase != .idle {
                Text(updates.status).font(.callout.weight(.medium))
            }
            if updates.phase == .downloading { ProgressView(value: updates.progress) }
            if updates.phase == .checking || updates.phase == .installing { ProgressView().controlSize(.small) }
            if let date = updates.installDate {
                HStack(spacing: 4) {
                    Text(L10n.text("Автоматический перезапуск через"))
                    Text(date, style: .timer).monospacedDigit()
                }.font(.caption)
            }
            if let failure = updates.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Text(L10n.text("Текущая установка и сохранённая статистика остаются доступны. Повторите проверку позже."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !updates.releaseNotes.isEmpty, [.available, .downloading, .ready].contains(updates.phase) {
                DisclosureGroup(L10n.text("Что нового")) {
                    Text(updates.releaseNotes).font(.caption).textSelection(.enabled)
                }
            }
            HStack {
                if updates.phase == .available {
                    Button(L10n.text("Скачать обновление")) { updates.download() }
                }
                if updates.phase == .ready {
                    Button(L10n.text("Установить и перезапустить")) { updates.install() }
                        .buttonStyle(.borderedProminent)
                }
                if [.checking, .available, .downloading, .ready].contains(updates.phase) {
                    Button(L10n.text("Позже")) { updates.postpone() }
                }
            }
        }
    }
}

struct AppMaintenanceSetup: View {
    @ObservedObject var updates: AppUpdateCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("Готово к работе"), systemImage: "checkmark.shield")
                .font(.title2.weight(.semibold))
            Text(L10n.text("LLM Usage включает ccusage \(CCUsageManifest.bundled?.version ?? "—") для расчёта локальной статистики."))
            Text(L10n.text("Компонент запускается только с вашего согласия. Устанавливать Node.js, npm или другие программы не потребуется."))
                .foregroundStyle(.secondary)
            Toggle(L10n.text("Проверять обновления автоматически"), isOn: $updates.preferences.checksAutomatically)
            Picker(L10n.text("При появлении новой версии"), selection: $updates.preferences.mode) {
                ForEach(AppUpdateMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Text(L10n.text("Разрешение распространяется на приложение и встроенный ccusage. Перед автоматическим перезапуском можно отложить установку."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("Расчёты выполняются локально. Для актуальных тарифов и обновлений приложение обращается в интернет."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("Позже")) { updates.presentsSetup = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Подключить и продолжить")) { updates.activate() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
        .interactiveDismissDisabled()
    }
}
