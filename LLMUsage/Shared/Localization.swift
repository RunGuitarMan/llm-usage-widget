import Foundation

/// Stable preference shared by the app and the WidgetKit process through RefreshStatus.
enum InterfaceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system, russian = "ru", english = "en"
    var id: String { rawValue }
    init(from decoder: Decoder) throws {
        self = InterfaceLanguage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
    }
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first
            if code == "ru" { return .russian }
            if code == "en" { return .english }
        }
        return .english
    }
    var locale: Locale { Locale(identifier: resolved() == .russian ? "ru_RU" : "en_US") }
    var title: String {
        switch self {
        case .system: return L10n.text("Системный")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}

/// Interpolation separates arguments from the lookup key. Transcript text, paths,
/// model names and tool names are arguments, never translation candidates.
struct LocalizedPhrase: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    var key: String
    var arguments: [String] = []
    init(stringLiteral value: String) { key = value }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            if let value = value as? Int { arguments.append(UsageFormat.exact(Int64(value))) }
            else if let value = value as? Int64 { arguments.append(UsageFormat.exact(value)) }
            else { arguments.append(String(describing: value)) }
        }
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var selection: InterfaceLanguage = .system
    /// Each process has one interface language. Mutations are lock-protected because
    /// the transcript reader and widget provider also format on background queues.
    static var preference: InterfaceLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selection }
        set { lock.lock(); selection = newValue; lock.unlock() }
    }
    static var language: InterfaceLanguage { preference.resolved() }
    static var locale: Locale { preference.locale }
    static func text(_ phrase: LocalizedPhrase, language: InterfaceLanguage? = nil) -> String {
        let template = key(phrase.key, language: language)
        // Parse placeholders once: an argument containing "{1}" must stay literal.
        let pattern = #"\{([0-9]+)\}"#
        let expression = try! NSRegularExpression(pattern: pattern)
        var rendered = template
        for match in expression.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let range = Range(match.range, in: rendered),
                  let indexRange = Range(match.range(at: 1), in: template),
                  let index = Int(template[indexRange]), phrase.arguments.indices.contains(index) else { continue }
            rendered.replaceSubrange(range, with: phrase.arguments[index])
        }
        return rendered
    }
    static func key(_ key: String, language: InterfaceLanguage? = nil) -> String {
        guard let pair = catalog[key] else { return key }
        return (language ?? preference).resolved() == .russian ? pair.ru : pair.en
    }
    enum CountNoun { case messages, actions, characters, sessions }
    static func count(_ count: Int, _ noun: CountNoun) -> String {
        let forms: (ru: [String], en: [String])
        switch noun {
        case .messages: forms = (["сообщение", "сообщения", "сообщений"], ["message", "messages"])
        case .actions: forms = (["действие", "действия", "действий"], ["action", "actions"])
        case .characters: forms = (["знак", "знака", "знаков"], ["character", "characters"])
        case .sessions: forms = (["сессия", "сессии", "сессий"], ["session", "sessions"])
        }
        let n = abs(count)
        let word: String
        if language == .russian {
            let index = (11...14).contains(n % 100) ? 2 : n % 10 == 1 ? 0 : (2...4).contains(n % 10) ? 1 : 2
            word = forms.ru[index]
        } else { word = forms.en[n == 1 ? 0 : 1] }
        return "\(UsageFormat.exact(Int64(count))) \(word)"
    }

    /// Single catalogue, compiled into both targets (also works with the CLT build).
    /// Russian source keys are stable lookup identifiers, not persisted enum values.
    static let catalog: [String: (ru: String, en: String)] = [
        "Показаны итоги с учётом исключений моделей.": ("Показаны итоги с учётом исключений моделей.", "Totals reflect your model exclusions."),
        "Учёт моделей": ("Учёт моделей", "Model inclusion"),
        "Выключите модель, чтобы исключить её токены и стоимость из итогов за все дни. Записи сессий сохраняются. Z.ai / GLM исключены по умолчанию.": ("Выключите модель, чтобы исключить её токены и стоимость из итогов за все дни. Записи сессий сохраняются. Z.ai / GLM исключены по умолчанию.", "Turn off a model to exclude its tokens and cost from totals for all dates. Session records are kept. Z.ai / GLM are excluded by default."),
        "Точное имя модели": ("Точное имя модели", "Exact model name"),
        "Исключить": ("Исключить", "Exclude"),
        "Если данные смешанной сессии нельзя разделить по моделям, она не включается в итоги, а сумма помечается как неполная.": ("Если данные смешанной сессии нельзя разделить по моделям, она не включается в итоги, а сумма помечается как неполная.", "If a mixed session's usage cannot be split by model, it is omitted from totals and the amount is marked incomplete."),
        "Основные": ("Основные", "General"),
        "Период по умолчанию": ("Период по умолчанию", "Default period"),
        "Сегодня": ("Сегодня", "Today"),
        "Часовой пояс": ("Часовой пояс", "Time zone"),
        "Обновлять каждые": ("Обновлять каждые", "Refresh every"),
        "Обновление данных": ("Обновление данных", "Data refresh"),
        "Быстрый режим": ("Быстрый режим", "Fast interval"),
        "Средний режим": ("Средний режим", "Medium interval"),
        "Медленный режим": ("Медленный режим", "Slow interval"),
        "Быстрый": ("Быстрый", "Fast"),
        "Средний": ("Средний", "Medium"),
        "Медленный": ("Медленный", "Slow"),
        "Текущий режим": ("Текущий режим", "Current mode"),
        "{0} сек": ("{0} сек", "{0} sec"),
        "При изменении суммы автообновления ускоряются. Минута без изменений — средний режим, ещё 3 минуты — медленный. Запуск начинается с медленного режима.": ("При изменении суммы автообновления ускоряются. Минута без изменений — средний режим, ещё 3 минуты — медленный. Запуск начинается с медленного режима.", "Automatic updates speed up when the cost changes. One unchanged minute switches to medium; another 3 minutes switches to slow. The app starts in slow mode."),
        "Ручное обновление пропускает ближайшее автообновление только в быстром режиме. Средний и медленный режимы сохраняют расписание.": ("Ручное обновление пропускает ближайшее автообновление только в быстром режиме. Средний и медленный режимы сохраняют расписание.", "A manual refresh skips the next automatic update only in fast mode. Medium and slow modes keep their schedule."),
        "{0} мин": ("{0} мин", "{0} min"),
        "Запускать при входе в систему": ("Запускать при входе в систему", "Launch at login"),
        "Приложение продолжает обновлять данные после закрытия окна. Управление доступно в строке меню.": ("Приложение продолжает обновлять данные после закрытия окна. Управление доступно в строке меню.", "The app keeps updating data after you close the window. Controls remain available in the menu bar."),
        "Виджеты": ("Виджеты", "Widgets"),
        "Сводка": ("Сводка", "Summary"),
        "Стоимость, токены и сессии": ("Стоимость, токены и сессии", "Cost, Tokens and sessions"),
        "Сессии": ("Сессии", "Sessions"),
        "Рейтинг по стоимости": ("Рейтинг по стоимости", "Ranked by cost"),
        "Динамика": ("Динамика", "Trend"),
        "Расходы за 7 дней": ("Расходы за 7 дней", "Spending over 7 days"),
        "Откройте галерею виджетов macOS и найдите LLM Usage. Каждый вариант доступен в трёх размерах; можно добавить несколько одновременно.": ("Откройте галерею виджетов macOS и найдите LLM Usage. Каждый вариант доступен в трёх размерах; можно добавить несколько одновременно.", "Open the macOS widget gallery and search for LLM Usage. Each variant comes in three sizes; you can add several at once."),
        "История загружается в фоне. Пропущенные дни отмечены прочерком, нулевые расходы — кружком. Сегодняшний день ещё не завершён.": ("История загружается в фоне. Пропущенные дни отмечены прочерком, нулевые расходы — кружком. Сегодняшний день ещё не завершён.", "History loads in the background. Dashes mark missing days; circles mark zero spending. Today is still in progress."),
        "Дневной бюджет": ("Дневной бюджет", "Daily budget"),
        "Показывать бюджет": ("Показывать бюджет", "Show budget"),
        "Сумма в USD": ("Сумма в USD", "Amount in USD"),
        "Применить": ("Применить", "Apply"),
        "Введите сумму больше нуля.": ("Введите сумму больше нуля.", "Enter an amount greater than zero."),
        "Ориентир для расходов за день в выбранном часовом поясе. Бюджет не останавливает сессии. При неполных ценах показывается только учтённая стоимость.": ("Ориентир для расходов за день в выбранном часовом поясе. Бюджет не останавливает сессии. При неполных ценах показывается только учтённая стоимость.", "A spending guide for each day in the selected time zone. The budget does not stop sessions. When prices are missing, only known costs are shown."),
        "Строка меню": ("Строка меню", "Menu bar"),
        "Содержимое меню": ("Содержимое меню", "Menu content"),
        "Компактный вид без LLM": ("Компактный вид без LLM", "Compact view without LLM"),
        "Предпросмотр": ("Предпросмотр", "Preview"),
        "Скрывает надпись LLM, оставляя сумму за сегодня. Изменение применяется сразу.": ("Скрывает надпись LLM, оставляя сумму за сегодня. Изменение применяется сразу.", "Hides the LLM label and keeps today’s amount. Changes apply immediately."),
        "Подключение ccusage": ("Подключение ccusage", "ccusage connection"),
        "Способ обновления": ("Способ обновления", "Update mode"),
        "Только Claude": ("Только Claude", "Claude only"),
        "Все агенты": ("Все агенты", "All agents"),
        "Статистика только Claude Code.": ("Статистика только Claude Code.", "Usage from Claude Code only."),
        "Claude Code, Codex и другие локальные агенты. Обновление может занимать больше времени.": ("Claude Code, Codex и другие локальные агенты. Обновление может занимать больше времени.", "Claude Code, Codex and other local agents. Updates may take longer."),
        "Источники": ("Источники", "Sources"),
        "Все поддерживаемые ccusage": ("Все поддерживаемые ccusage", "All sources supported by ccusage"),
        "Claude Code, Codex, Gemini CLI, OpenCode, Copilot и другие локальные агенты. Новые источники подключаются по мере обновления ccusage. Веб-чаты без локальных логов не учитываются.": ("Claude Code, Codex, Gemini CLI, OpenCode, Copilot и другие локальные агенты. Новые источники подключаются по мере обновления ccusage. Веб-чаты без локальных логов не учитываются.", "Claude Code, Codex, Gemini CLI, OpenCode, Copilot and other local agents. New sources are added as ccusage is updated. Web chats without local logs are excluded."),
        "Путь к ccusage": ("Путь к ccusage", "ccusage path"),
        "Автоматическое определение": ("Автоматическое определение", "Detect automatically"),
        "Выбрать…": ("Выбрать…", "Choose…"),
        "Найти автоматически": ("Найти автоматически", "Find automatically"),
        "Проверить": ("Проверить", "Check"),
        "ccusage найден": ("ccusage найден", "ccusage found"),
        "Ошибка": ("Ошибка", "Error"),
        "Статистика обрабатывается на этом Mac. ccusage проверяет тарифы в интернете; если источник недоступен, использует встроенные цены. Стоимость — оценка, а не счёт за подписку.": ("Статистика обрабатывается на этом Mac. ccusage проверяет тарифы в интернете; если источник недоступен, использует встроенные цены. Стоимость — оценка, а не счёт за подписку.", "Statistics are processed on this Mac. ccusage checks prices online and uses built-in prices if the source is unavailable. Cost is an estimate, not a subscription bill."),
        "Хранилище и диагностика": ("Хранилище и диагностика", "Storage and diagnostics"),
        "Последняя попытка": ("Последняя попытка", "Last attempt"),
        "Последнее успешное обновление": ("Последнее успешное обновление", "Last successful update"),
        "Данные виджета": ("Данные виджета", "Widget data"),
        "Локальные снимки статистики": ("Локальные снимки статистики", "Local usage snapshots"),
        "Ошибка хранилища": ("Ошибка хранилища", "Storage error"),
        "Обновить сейчас": ("Обновить сейчас", "Refresh now"),
        "macOS сама планирует обновления WidgetKit. Виджет может перерисовываться позже, чем приложение получает данные.": ("macOS сама планирует обновления WidgetKit. Виджет может перерисовываться позже, чем приложение получает данные.", "macOS schedules WidgetKit updates. The widget may refresh later than the app receives data."),
        "Технические подробности": ("Технические подробности", "Technical details"),
        "LLM Usage 1.1 · Данные на этом Mac": ("LLM Usage 1.1 · Данные на этом Mac", "LLM Usage 1.1 · Data on this Mac"),
        "Разрешите запуск в System Settings → General → Login Items.": ("Разрешите запуск в Системных настройках → Основные → Объекты входа.", "Allow launch in System Settings → General → Login Items."),
        "Не удалось изменить автозапуск. Переместите подписанное приложение в Applications и проверьте Login Items.": ("Не удалось изменить автозапуск. Переместите подписанное приложение в «Программы» и проверьте «Объекты входа».", "Could not change launch at login. Move the signed app to Applications and check Login Items."),
        "Выберите ccusage": ("Выберите ccusage", "Choose ccusage"),
        "Выберите установленный executable или исполняемый скрипт ccusage.": ("Выберите установленный executable или исполняемый скрипт ccusage.", "Choose an installed ccusage executable or executable script."),
        "ccusage не найден": ("ccusage не найден", "ccusage not found"),
        "Настройки…": ("Настройки…", "Settings…"),
        "Открыть Dashboard": ("Открыть обзор", "Open dashboard"),
        "Показать статистику в строке меню": ("Показать статистику в строке меню", "Show usage in menu bar"),
        "Вчера": ("Вчера", "Yesterday"),
        "Другая дата": ("Другая дата", "Another date"),
        "Загружаем статистику…": ("Загружаем статистику…", "Loading usage…"),
        "Открыть обзор": ("Открыть обзор", "Open overview"),
        "Обновляем…": ("Обновляем…", "Refreshing…"),
        "Обновить": ("Обновить", "Refresh"),
        "Настройки · ⌘,": ("Настройки · ⌘,", "Settings · ⌘,"),
        "Настройки": ("Настройки", "Settings"),
        "Завершить LLM Usage": ("Завершить LLM Usage", "Quit LLM Usage"),
        "{0} Tokens  ·  Сессии: {1}": ("{0} Tokens  ·  Сессии: {1}", "{0} Tokens  ·  Sessions: {1}"),
        "Стоимость неполная": ("Стоимость неполная", "Cost incomplete"),
        "Обновлено {0} · данные устарели": ("Обновлено {0} · данные устарели", "Updated {0} · data is outdated"),
        "За 7 дней": ("За 7 дней", "Last 7 days"),
        "LLM Usage, сегодня {0}": ("LLM Usage, сегодня {0}", "LLM Usage, today {0}"),
        "LLM Usage, статистика загружается": ("LLM Usage, статистика загружается", "LLM Usage, loading usage"),
        "LLM Usage · {0} за сегодня · нажмите для подробностей": ("LLM Usage · {0} за сегодня · нажмите для подробностей", "LLM Usage · {0} today · click for details"),
        "LLM Usage · загружаем статистику": ("LLM Usage · загружаем статистику", "LLM Usage · loading usage"),
        "По стоимости": ("По стоимости", "By cost"),
        "Сессии: {0} · по стоимости": ("Сессии: {0} · по стоимости", "Sessions: {0} · by cost"),
        "Данные неполные или устарели": ("Данные неполные или устарели", "Data is incomplete or outdated"),
        "Пока нет сессий": ("Пока нет сессий", "No sessions yet"),
        "{0}, {1}, сессия {2}, {3}. Открыть сессию": ("{0}, {1}, сессия {2}, {3}. Открыть сессию", "{0}, {1}, session {2}, {3}. Open session"),
        "Не удалось обновить": ("Не удалось обновить", "Could not refresh"),
        "Данные устарели": ("Данные устарели", "Data is outdated"),
        "Нет данных за сегодня": ("Нет данных за сегодня", "No data for today"),
        "{0} {1}, чем вчера": ("{0} {1}, чем вчера", "{0} {1} than yesterday"),
        "больше": ("больше", "more"),
        "меньше": ("меньше", "less"),
        "Стоимость, токены и сессии всех локальных LLM-агентов за сегодня.": ("Стоимость, токены и сессии всех локальных LLM-агентов за сегодня.", "Today’s cost, Tokens and sessions across all local LLM agents."),
        "Сессии за день по стоимости. Нажмите на строку, чтобы открыть сессию.": ("Сессии за день по стоимости. Нажмите на строку, чтобы открыть сессию.", "Today’s sessions ranked by cost. Click a row to open the session."),
        "Реальные расходы за 7 дней. Пробелы означают, что данные ещё не получены.": ("Реальные расходы за 7 дней. Пробелы означают, что данные ещё не получены.", "Actual spending over 7 days. Gaps mean data has not been collected yet."),
        "Сессии: {0}": ("Сессии: {0}", "Sessions: {0}"),
        "Модель неизвестна": ("Модель неизвестна", "Unknown model"),
        "{0}, {1}, сессия {2}, {3}, {4} токенов. Открыть сессию": ("{0}, {1}, сессия {2}, {3}, {4} токенов. Открыть сессию", "{0}, {1}, session {2}, {3}, {4} Tokens. Open session"),
        "Обновлено": ("Обновлено", "Updated"),
        "Данные\nнедоступны": ("Данные\nнедоступны", "Data\nunavailable"),
        "Откройте\nLLM Usage": ("Откройте\nLLM Usage", "Open\nLLM Usage"),
        "Откройте LLM Usage": ("Откройте LLM Usage", "Open LLM Usage"),
        "Проверьте хранилище в настройках приложения.": ("Проверьте хранилище в настройках приложения.", "Check storage in the app’s settings."),
        "Обновите данные в приложении.": ("Обновите данные в приложении.", "Refresh data in the app."),
        "Настройте ccusage, чтобы видеть расходы здесь.": ("Настройте ccusage, чтобы видеть расходы здесь.", "Set up ccusage to see spending here."),
        "Обзор": ("Обзор", "Overview"),
        "Модели": ("Модели", "Models"),
        "Сегодня, {0}": ("Сегодня, {0}", "Today, {0}"),
        "Вчера, {0}": ("Вчера, {0}", "Yesterday, {0}"),
        "По токенам": ("По токенам", "By Tokens"),
        "По активности": ("По активности", "By activity"),
        "По Output": ("По Output", "By Output"),
        "По Cache read": ("По Cache read", "By Cache read"),
        "Проверьте путь к ccusage": ("Проверьте путь к ccusage", "Check the ccusage path"),
        "Не удалось получить статистику": ("Не удалось получить статистику", "Could not load usage"),
        "ccusage не ответил вовремя": ("ccusage не ответил вовремя", "ccusage timed out"),
        "Не удалось прочитать ответ ccusage": ("Не удалось прочитать ответ ccusage", "Could not read the ccusage response"),
        "Общее хранилище виджета недоступно": ("Общее хранилище виджета недоступно", "Widget shared storage is unavailable"),
        "Ответ ccusage слишком большой": ("Ответ ccusage слишком большой", "The ccusage response is too large"),
        "Установите ccusage или укажите путь к существующему executable.": ("Установите ccusage или укажите путь к существующему executable.", "Install ccusage or specify the path to an existing executable."),
        "Проверьте ccusage в настройках и повторите обновление. Последние успешные данные сохранены.": ("Проверьте ccusage в настройках и повторите обновление. Последние успешные данные сохранены.", "Check ccusage in Settings and try refreshing again. Your last successful data is saved."),
        "Проверьте версию ccusage. Подробности доступны в настройках.": ("Проверьте версию ccusage. Подробности доступны в настройках.", "Check the ccusage version. Details are available in Settings."),
        "Переустановите приложение вместе с расширением и повторите обновление данных.": ("Переустановите приложение вместе с расширением и повторите обновление данных.", "Reinstall the app together with its extension, then refresh the data."),
        "Проверьте Signing Team и одинаковый App Group у приложения и расширения.": ("Проверьте Signing Team и одинаковый App Group у приложения и расширения.", "Check the Signing Team and make sure the app and extension use the same App Group."),
        "Выберите другой день или проверьте executable в настройках.": ("Выберите другой день или проверьте executable в настройках.", "Choose another day or check the executable in Settings."),
        "Бюджет {0}": ("Бюджет {0}", "Budget {0}"),
        "Дневной бюджет {0}. Учтено {1}. {2}": ("Дневной бюджет {0}. Учтено {1}. {2}", "Daily budget {0}. Recorded {1}. {2}"),
        "{0}: нет данных": ("{0}: нет данных", "{0}: no data"),
        ", неполный день": (", неполный день", ", partial day"),
        ", стоимость неполная": (", стоимость неполная", ", cost incomplete"),
        "Дней без данных: {0} · —": ("Дней без данных: {0} · —", "Days without data: {0} · —"),
        "Сегодня — неполный день": ("Сегодня — неполный день", "Today is a partial day"),
        "Время не указано": ("Время не указано", "Time not provided"),
        "Расходы: {0}{1}": ("Расходы: {0}{1}", "Spending: {0}{1}"),
        "{0}: {1} токенов": ("{0}: {1} токенов", "{0}: {1} Tokens"),
        "Статистика появится после работы в Claude Code, Codex или другом агенте, поддерживаемом ccusage.": ("Статистика появится после работы в Claude Code, Codex или другом агенте, поддерживаемом ccusage.", "Usage will appear after working in Claude Code, Codex or another agent supported by ccusage."),
        "Сводка токенов": ("Сводка токенов", "Token summary"),
        "Динамика за 7 дней": ("Динамика за 7 дней", "7-day trend"),
        "Превышение {0}{1}": ("Превышение {0}{1}", "Over by {0}{1}"),
        "Учтена часть стоимости": ("Учтена часть стоимости", "Only part of the cost is known"),
        "Осталось {0}": ("Осталось {0}", "Remaining {0}"),
        "Расходы по моделям": ("Расходы по моделям", "Spending by model"),
        "Модели: {0} · По убыванию стоимости": ("Модели: {0} · По убыванию стоимости", "Models: {0} · Highest cost first"),
        "Как учитываются модели": ("Как учитываются модели", "How models are counted"),
        "Если ccusage не предоставил полную разбивку по моделям, смешанная сессия остаётся одной общей строкой. Так токены и стоимость не учитываются дважды.": ("Если ccusage не предоставил полную разбивку по моделям, смешанная сессия остаётся одной общей строкой. Так токены и стоимость не учитываются дважды.", "If ccusage does not provide a complete model breakdown, a mixed session stays in one combined row. This prevents double-counting Tokens and cost."),
        "Часть данных для расчёта недоступна": ("Часть данных для расчёта недоступна", "Some calculation data is unavailable"),
        "Сессии: {0} · {1} токенов": ("Сессии: {0} · {1} токенов", "Sessions: {0} · {1} Tokens"),
        "Период · {0}": ("Период · {0}", "Period · {0}"),
        "Период: {0}": ("Период: {0}", "Period: {0}"),
        "Все источники": ("Все источники", "All sources"),
        "Демо-данные": ("Демо-данные", "Demo data"),
        "Обновление…": ("Обновление…", "Refreshing…"),
        "Обновлено {0}": ("Обновлено {0}", "Updated {0}"),
        "Локальные данные": ("Локальные данные", "Local data"),
        "Показать: {0}": ("Показать: {0}", "Show: {0}"),
        "Не удалось обновить данные": ("Не удалось обновить данные", "Could not refresh data"),
        "Дата": ("Дата", "Date"),
        "Обновить статистику · ⌘R": ("Обновить статистику · ⌘R", "Refresh usage · ⌘R"),
        "Обновить статистику": ("Обновить статистику", "Refresh usage"),
        "Читаем локальную статистику…": ("Читаем локальную статистику…", "Reading local usage…"),
        "Подключите ccusage": ("Подключите ccusage", "Connect ccusage"),
        "Расходы и активность локальных AI-агентов появятся здесь.": ("Расходы и активность локальных AI-агентов появятся здесь.", "Spending and activity from local AI agents will appear here."),
        "Выбрать файл…": ("Выбрать файл…", "Choose file…"),
        "Часть данных для расчёта недоступна. Показаны только учтённые токены и известная стоимость.": ("Часть данных для расчёта недоступна. Показаны только учтённые токены и известная стоимость.", "Some calculation data is unavailable. Only accounted tokens and known costs are shown."),
        "Основные расходы": ("Основные расходы", "Top spending"),
        "Данные на этом Mac · Стоимость рассчитана по тарифам ccusage": ("Данные на этом Mac · Стоимость рассчитана по тарифам ccusage", "Data on this Mac · Cost based on ccusage prices"),
        "Состав токенов": ("Состав токенов", "Token breakdown"),
        "Развёрнуто": ("Развёрнуто", "Expanded"),
        "Свёрнуто": ("Свёрнуто", "Collapsed"),
        "Все сессии": ("Все сессии", "All sessions"),
        "Расходы за сегодня": ("Сегодня", "Today"),
        "Расходы за вчера": ("Вчера", "Yesterday"),
        "Расходы: {0}": ("Расходы: {0}", "Spending: {0}"),
        "Оценка стоимости · {0}": ("Оценка стоимости · {0}", "Estimated cost · {0}"),
        "токенов": ("Tokens", "Tokens"),
        "По источникам": ("По источникам", "By source"),
        "Фильтр: {0}": ("Фильтр: {0}", "Filter: {0}"),
        " токенов": (" токенов", " Tokens"),
        "{0} токенов": ("{0} токенов", "{0} Tokens"),
        "{0}, {1}, {2}, {3} токенов. Подробности": ("{0}, {1}, {2}, {3} токенов. Подробности", "{0}, {1}, {2}, {3} Tokens. Details"),
        "Ничего не найдено": ("Ничего не найдено", "Nothing found"),
        "Выберите другой день или измените фильтры.": ("Выберите другой день или измените фильтры.", "Choose another day or change the filters."),
        "Сессия": ("Сессия", "Session"),
        "· {0} токенов": ("· {0} токенов", "· {0} Tokens"),
        "Стоимость": ("Стоимость", "Cost"),
        "Токены": ("Tokens", "Tokens"),
        "Источник": ("Источник", "Source"),
        "Активность": ("Активность", "Activity"),
        "Подробности": ("Подробности", "Details"),
        "Скопировать ID": ("Скопировать ID", "Copy ID"),
        "Найти сессию": ("Найти сессию", "Find a session"),
        "Сессии: {0} · {1}": ("Сессии: {0} · {1}", "Sessions: {0} · {1}"),
        "За период": ("За период", "For period"),
        "Найдено": ("Найдено", "Found"),
        "Модель": ("Модель", "Model"),
        "Все модели": ("Все модели", "All models"),
        "Сортировка": ("Сортировка", "Sort"),
        "Фильтры и сортировка сессий": ("Фильтры и сортировка сессий", "Session filters and sorting"),
        "Фильтры сессий": ("Фильтры сессий", "Session filters"),
        "Сбросить фильтр модели": ("Сбросить фильтр модели", "Clear model filter"),
        "Модель, проект или сессия": ("Модель, проект или сессия", "Model, project or session"),
        "Подробности сессии": ("Подробности сессии", "Session details"),
        "Закрыть подробности": ("Закрыть подробности", "Close details"),
        "Скопировано": ("Скопировано", "Copied"),
        "Скопировать полный ID": ("Скопировать полный ID", "Copy full ID"),
        "Просмотреть чат": ("Просмотреть чат", "View chat"),
        "Сообщения, ответы и действия в этой сессии": ("Сообщения, ответы и действия в этой сессии", "Messages, replies and actions in this session"),
        "Стоимость неполная: часть данных недоступна.": ("Стоимость неполная: часть данных недоступна.", "Cost is incomplete: some data is unavailable."),
        "Дополнительная информация": ("Дополнительная информация", "Additional information"),
        "Последняя активность": ("Последняя активность", "Last activity"),
        "Проект": ("Проект", "Project"),
        "{0} токенов — уже включены в Output.": ("{0} токенов — уже включены в Output.", "{0} Tokens — already included in Output."),
        "Other tokens входят в общую сумму и не относятся к четырём основным категориям.": ("Other tokens входят в общую сумму и не относятся к четырём основным категориям.", "Other tokens are included in the total and do not belong to the four main categories."),
        "Загружаем сессию…": ("Загружаем сессию…", "Loading session…"),
        "Сессия недоступна за выбранный день. Выберите другую дату.": ("Сессия недоступна за выбранный день. Выберите другую дату.", "This session is unavailable for the selected day. Choose another date."),
        "Открываем историю…": ("Открываем историю…", "Opening history…"),
        "Поиск в чате": ("Поиск в чате", "Search chat"),
        "История чата": ("История чата", "Chat history"),
        "· Демо": ("· Демо", "· Demo"),
        "Служебные события": ("Служебные события", "System events"),
        "Информация о сессии": ("Информация о сессии", "Session information"),
        "Скопировать историю": ("Скопировать историю", "Copy history"),
        "Сохранить историю…": ("Сохранить историю…", "Save history…"),
        "Открыть файл чата…": ("Открыть файл чата…", "Open chat file…"),
        "Открыть основной журнал": ("Открыть основной журнал", "Open main log"),
        "Другие журналы": ("Другие журналы", "Other logs"),
        "Показать журнал в Finder": ("Показать журнал в Finder", "Show log in Finder"),
        "Действия с историей": ("Действия с историей", "History actions"),
        "Закрыть чат · Esc": ("Закрыть чат · Esc", "Close chat · Esc"),
        "Закрыть чат": ("Закрыть чат", "Close chat"),
        "Найти в сообщениях и действиях": ("Найти в сообщениях и действиях", "Search messages and actions"),
        "Найдено: {0}": ("Найдено: {0}", "Found: {0}"),
        "сообщение": ("сообщение", "message"),
        "сообщения": ("сообщения", "messages"),
        "сообщений": ("сообщений", "messages"),
        "действие": ("действие", "action"),
        "действия": ("действия", "actions"),
        "действий": ("действий", "actions"),
        "Время событий: {0}. История за всю сессию.": ("Время событий: {0}. История за всю сессию.", "Event time zone: {0}. History covers the entire session."),
        "О доступности истории": ("О доступности истории", "About history availability"),
        "Нет сообщений для показа": ("Нет сообщений для показа", "No messages to show"),
        "Совпадений нет": ("Совпадений нет", "No matches"),
        "Откройте служебные события в меню, чтобы изучить доступные записи.": ("Откройте служебные события в меню, чтобы изучить доступные записи.", "Open system events in the menu to inspect the available records."),
        "Попробуйте другое слово или часть команды.": ("Попробуйте другое слово или часть команды.", "Try another word or part of a command."),
        "Показать служебные события ({0})": ("Показать служебные события ({0})", "Show system events ({0})"),
        "В начало чата": ("В начало чата", "Go to start of chat"),
        "К последнему сообщению": ("К последнему сообщению", "Go to latest message"),
        "Вы": ("Вы", "You"),
        "Скопировать сообщение": ("Скопировать сообщение", "Copy message"),
        "Прочитать полностью": ("Прочитать полностью", "Read in full"),
        "Исходная запись": ("Исходная запись", "Original record"),
        "Действия с сообщением": ("Действия с сообщением", "Message actions"),
        "Читать полностью · {0} знаков": ("Читать полностью · {0} знаков", "Read in full · {0} characters"),
        "Совпадение в полном содержимом": ("Совпадение в полном содержимом", "Match in full content"),
        "Передано": ("Передано", "Sent"),
        "Получено": ("Получено", "Received"),
        "Получен пустой результат.": ("Получен пустой результат.", "An empty result was received."),
        "Результат не записан в журнале.": ("Результат не записан в журнале.", "No result was recorded in the log."),
        "Скопировать: {0}": ("Скопировать: {0}", "Copy: {0}"),
        "Открыть полностью": ("Открыть полностью", "Open in full"),
        "Открыть полностью: {0}": ("Открыть полностью: {0}", "Open in full: {0}"),
        "Служебные события · {0}": ("Служебные события · {0}", "System events · {0}"),
        "История пока недоступна": ("История пока недоступна", "History is not available yet"),
        "Выберите сохранённый файл чата.": ("Выберите сохранённый файл чата.", "Choose a saved chat file."),
        "История сессии": ("История сессии", "Session history"),
        "Открыть сохранённую историю чата": ("Открыть сохранённую историю чата", "Open saved chat history"),
        "Не удалось сохранить историю: {0}": ("Не удалось сохранить историю: {0}", "Could not save history: {0}"),
        "Скопировать": ("Скопировать", "Copy"),
        "Готово": ("Готово", "Done"),
        "Полное содержимое записи": ("Полное содержимое записи", "Full record content"),
        "Ответ": ("Ответ", "Reply"),
        "Контекст запроса": ("Контекст запроса", "Request context"),
        "Передано:\n{0}": ("Передано:\n{0}", "Sent:\n{0}"),
        "Получено:\n{0}": ("Получено:\n{0}", "Received:\n{0}"),
        "Исходная запись:\n{0}": ("Исходная запись:\n{0}", "Original record:\n{0}"),
        "Служебное событие": ("Служебное событие", "System event"),
        "Действие": ("Действие", "Action"),
        "Контекст": ("Контекст", "Context"),
        "Изображение": ("Изображение", "Image"),
        "Вложение · {0}": ("Вложение · {0}", "Attachment · {0}"),
        "[{0} — данные в исходной записи]": ("[{0} — данные в исходной записи]", "[{0} — data is in the original record]"),
        "Окружение сессии": ("Окружение сессии", "Session environment"),
        "Инструкции и контекст": ("Инструкции и контекст", "Instructions and context"),
        "Служебная запись": ("Служебная запись", "System record"),
        "Дополнительный контекст": ("Дополнительный контекст", "Additional context"),
        "Вызов инструмента": ("Вызов инструмента", "Tool call"),
        "Результат инструмента": ("Результат инструмента", "Tool result"),
        "Нужен общий отчёт ccusage session с полями session, agent и period. Обновите ccusage до версии с поддержкой всех источников (проверено с 20.0.26).": ("Нужен общий отчёт ccusage session с полями session, agent и period. Обновите ccusage до версии с поддержкой всех источников (проверено с 20.0.26).", "A combined ccusage session report with session, agent and period fields is required. Update ccusage to a version that supports all sources (verified with 20.0.26)."),
        "История слишком велика для открытия целиком (более 256 МБ). Выберите отдельный файл или откройте журнал в редакторе.": ("История слишком велика для открытия целиком (более 256 МБ). Выберите отдельный файл или откройте журнал в редакторе.", "The history is too large to open in full (over 256 MB). Choose an individual file or open the log in an editor."),
        "Для {0} пока нет автоматического поиска истории. Можно открыть сохранённый чат в JSON или JSONL.": ("Для {0} пока нет автоматического поиска истории. Можно открыть сохранённый чат в JSON или JSONL.", "Automatic history discovery is not yet available for {0}. You can open a saved chat in JSON or JSONL."),
        "В базе найдены только служебные записи. Текст переписки в этом формате недоступен.": ("В базе найдены только служебные записи. Текст переписки в этом формате недоступен.", "Only system records were found in the database. Chat text is unavailable in this format."),
        "Antigravity хранит эту историю в бинарном формате. Текст чата из него пока не читается. Можно открыть JSON-экспорт сессии.": ("Antigravity хранит эту историю в бинарном формате. Текст чата из него пока не читается. Можно открыть JSON-экспорт сессии.", "Antigravity stores this history in a binary format that cannot yet be read as chat text. You can open a JSON session export."),
        "Не удалось найти сохранённую переписку этой сессии. История могла быть удалена, отключена или сохранена в другой папке. Выберите файл чата вручную.": ("Не удалось найти сохранённую переписку этой сессии. История могла быть удалена, отключена или сохранена в другой папке. Выберите файл чата вручную.", "Could not find this session’s saved conversation. History may have been deleted, disabled or saved in another folder. Choose the chat file manually."),
        " Часть папок недоступна для чтения.": (" Часть папок недоступна для чтения.", " Some folders could not be read."),
        "Есть дополнительные журналы этой сессии. Они доступны в меню «Другие журналы».": ("Есть дополнительные журналы этой сессии. Они доступны в меню «Другие журналы».", "Additional logs exist for this session. Open them from the “Other logs” menu."),
        "Некоторые папки не удалось проверить. Можно выбрать файл вручную.": ("Некоторые папки не удалось проверить. Можно выбрать файл вручную.", "Some folders could not be checked. You can choose a file manually."),
        "Открыт выбранный файл. Его содержимое может отличаться от сессии в статистике.": ("Открыт выбранный файл. Его содержимое может отличаться от сессии в статистике.", "The selected file is open. Its contents may differ from the session in usage statistics."),
        "Не удалось разобрать строк: {0}. Они сохранены в служебных событиях; история может быть неполной.": ("Не удалось разобрать строк: {0}. Они сохранены в служебных событиях; история может быть неполной.", "Could not parse {0} lines. They are preserved in system events; history may be incomplete."),
        "Файл пока не содержит записей. Обновите историю после следующего сообщения.": ("Файл пока не содержит записей. Обновите историю после следующего сообщения.", "The file does not contain any records yet. Refresh history after the next message."),
        "В журнале нет распознанных сообщений. Все доступные записи находятся в служебных событиях.": ("В журнале нет распознанных сообщений. Все доступные записи находятся в служебных событиях.", "No recognized messages were found in the log. All available records are under system events."),
        "Не удалось открыть базу истории: {0}.": ("Не удалось открыть базу истории: {0}.", "Could not open the history database: {0}."),
        "Формат базы истории не удалось прочитать.": ("Формат базы истории не удалось прочитать.", "Could not read the history database format."),
        "База истории занята или повреждена. Попробуйте обновить чат.": ("База истории занята или повреждена. Попробуйте обновить чат.", "The history database is busy or damaged. Try refreshing the chat."),
        "[Бинарные данные: {0} байт]": ("[Бинарные данные: {0} байт]", "[Binary data: {0} bytes]"),
        "Системный": ("Системный", "System"),
        "Язык интерфейса": ("Язык интерфейса", "Interface language"),
        "Код выхода: {0}\n{1}": ("Код выхода: {0}\n{1}", "Exit code: {0}\n{1}"),
        "Duplicate source/session identity in ccusage response": ("Повторяющийся источник или ID сессии в ответе ccusage", "Duplicate source/session identity in ccusage response"),
        "Missing session ID or agent in ccusage response": ("В ответе ccusage отсутствует ID сессии или агент", "Missing session ID or agent in ccusage response"),
        "Out-of-range reasoning token count": ("Количество Reasoning Tokens вне допустимого диапазона", "Out-of-range reasoning token count"),
        "Negative, non-finite or out-of-range usage value": ("Отрицательное, бесконечное или недопустимое значение статистики", "Negative, non-finite or out-of-range usage value"),
        "Total token count is inconsistent with its components": ("Общая сумма Tokens не совпадает с её составляющими", "Total token count is inconsistent with its components"),
        "Unsupported snapshot schema version": ("Неподдерживаемая версия формата снимка", "Unsupported snapshot schema version"),
        "Invalid values in saved snapshot": ("Некорректные значения в сохранённом снимке", "Invalid values in saved snapshot"),
        "Invalid saved daily history": ("Некорректная сохранённая история расходов", "Invalid saved daily history"),
        "File": ("Файл", "File"),
        "Edit": ("Правка", "Edit"),
        "View": ("Вид", "View"),
        "Window": ("Окно", "Window"),
        "Help": ("Справка", "Help"),
        "About LLM Usage": ("Об LLM Usage", "About LLM Usage"),
        "Hide LLM Usage": ("Скрыть LLM Usage", "Hide LLM Usage"),
        "Hide Others": ("Скрыть остальные", "Hide Others"),
        "Show All": ("Показать все", "Show All"),
        "Services": ("Службы", "Services"),
        "New Window": ("Новое окно", "New Window"),
        "Close Window": ("Закрыть окно", "Close Window"),
        "Close": ("Закрыть", "Close"),
        "Minimize": ("Свернуть", "Minimize"),
        "Zoom": ("Увеличить", "Zoom"),
        "Bring All to Front": ("Все окна на передний план", "Bring All to Front"),
        "Undo": ("Отменить", "Undo"),
        "Redo": ("Повторить", "Redo"),
        "Cut": ("Вырезать", "Cut"),
        "Copy": ("Скопировать", "Copy"),
        "Paste": ("Вставить", "Paste"),
        "Paste and Match Style": ("Вставить и согласовать стиль", "Paste and Match Style"),
        "Delete": ("Удалить", "Delete"),
        "Select All": ("Выбрать всё", "Select All"),
        "Enter Full Screen": ("На весь экран", "Enter Full Screen"),
        "Exit Full Screen": ("Выйти из полноэкранного режима", "Exit Full Screen"),
        "Show Sidebar": ("Показать боковое меню", "Show Sidebar"),
        "Hide Sidebar": ("Скрыть боковое меню", "Hide Sidebar"),
        "Toggle Sidebar": ("Боковое меню", "Toggle Sidebar"),
        "Show Toolbar": ("Показать панель инструментов", "Show Toolbar"),
        "Hide Toolbar": ("Скрыть панель инструментов", "Hide Toolbar"),
        "Customize Toolbar…": ("Настроить панель инструментов…", "Customize Toolbar…"),
        "LLM Usage Help": ("Справка LLM Usage", "LLM Usage Help"),
        "Open": ("Открыть", "Open"),
        "Save": ("Сохранить", "Save"),
        "Cancel": ("Отменить", "Cancel"),
    ]
}
