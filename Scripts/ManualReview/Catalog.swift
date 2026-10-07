import SwiftUI
import WidgetKit

enum ReviewFixture: String, CaseIterable {
    case normal, many, navigation, dailyCosts, providers, empty, loading, missing, failure, refreshing, stale, partial, huge, zero, gaps, storage
    var title: String {
        switch self {
        case .normal: return "Обычные данные"
        case .many: return "40 сессий"
        case .navigation: return "Переходы к сессиям"
        case .dailyCosts: return "Расходы по дням"
        case .providers: return "Логотипы моделей и TGPT"
        case .empty: return "Нет сессий"
        case .loading: return "Первая загрузка"
        case .missing: return "Нет подключения"
        case .failure: return "Ошибка с сохранёнными данными"
        case .refreshing: return "Обновление с данными"
        case .stale: return "Устаревшие данные"
        case .partial: return "Неполная стоимость"
        case .huge: return "Большие числа и длинные названия"
        case .zero: return "Нулевые токены"
        case .gaps: return "Пропуски истории"
        case .storage: return "Ошибка хранилища"
        }
    }
    func snapshot(day: UsageDay) -> UsageSnapshot? {
        if [.loading, .missing, .storage].contains(self) { return nil }
        var data = SampleData.multiSourceSnapshot()
        data.day = day
        if self == .providers {
            let rows: [(String, [String], String)] = [
                ("tgpt", ["tgpt/super-mega-llm-999b"], "claude"),
                ("glm", ["openrouter/z-ai/glm-5"], "claude"),
                ("mixed", ["claude-sonnet-4.6", "tgpt/gpt-6", "unknown-model"], "codex"),
                ("anthropic", ["claude-sonnet-4.6"], "claude"),
                ("unknown", ["custom-model"], "claude"),
                ("openai", ["gpt-6"], "claude"),
                ("google", ["gemini-2.5-pro"], "codex"),
                ("deepseek", ["deepseek-chat"], "claude"),
                ("qwen", ["Qwen/Qwen3-32B"], "opencode"),
                ("moonshot", ["moonshotai/kimi-k2"], "claude"),
                ("minimax", ["MiniMax-M2"], "opencode"),
                ("mistral", ["mistralai/codestral-latest"], "claude"),
                ("meta", ["meta-llama/Llama-3.3-70B-Instruct"], "codex"),
                ("empty", [], "claude"),
                ("breakdown", [], "claude")
            ]
            data.sessions = rows.enumerated().map { index, row in
                UsageSession(id: "provider-" + row.0, models: row.1,
                             usage: .init(input: Int64(1_000 * (rows.count - index)), cost: Double(rows.count - index)),
                             agent: row.2)
            }
            data.sessions[data.sessions.count - 1].modelBreakdowns = [
                .init(id: "zhipuai/glm4.7", usage: .init(input: 500, cost: 0.5)),
                .init(id: "tgpt/claude-opus", usage: .init(input: 500, cost: 0.5))
            ]
        }
        if self == .dailyCosts {
            let multiplier = Double((Int(day.key.suffix(2)) ?? 1) % 7 + 1) / 4
            for index in data.sessions.indices { data.sessions[index].usage.cost *= multiplier }
        }
        if self == .navigation {
            data.sessions = (0..<20).map { index in
                UsageSession(id: "navigation-\(index)", models: ["claude-navigation-\(index)"],
                             usage: .init(input: 100, cost: Double(20 - index)))
            }
        }
        if self == .stale { data.generatedAt = Date().addingTimeInterval(-7200) }
        if self == .empty { data.sessions = [] }
        if self == .many {
            let base = data.sessions
            data.sessions = (0..<40).map { index in
                var row = base[index % base.count]
                row.id = "review-session-\(index)"
                row.originalID = "00000000-0000-4000-8000-\(String(format: "%012d", index))"
                row.projectPath = "/ui-review/projects/project-\(index)"
                row.usage.cost += Double(index) / 10
                return row
            }
        }
        if self == .huge {
            data.sessions[0].models = ["custom-model-with-a-very-long-name-and-experimental-release-2026-10-04"]
            data.sessions[0].usage = .init(input: 123_456_789, output: 23_456_789, cost: 123_456.78)
            data.sessions[0].projectPath = "/ui-review/очень-длинное-название-проекта/папка-с-пробелами/ещё-одна-вложенная-папка"
            data.sessions[0].originalID = String(repeating: "long-session-id-", count: 6)
            data.sessions[1].models = ["claude-sonnet-4.6", "gpt-6-astra"]
        }
        if self == .partial { data.sessions[0].usage.costIsIncomplete = true }
        if self == .zero {
            for index in data.sessions.indices { data.sessions[index].usage = .zero }
        }
        return data
    }
    var error: UsageError? {
        switch self {
        case .missing: return .missingExecutable
        case .failure: return .timedOut
        default: return nil
        }
    }
}

enum ReviewTarget {
    case dashboard(DashboardTab, ReviewFixture, String)
    case chat(String)
    case menu(ReviewFixture, MenuContentMode, Bool)
    case widgets(UsageWidgetVariant, ReviewFixture)
    case transition(Int)
}

struct ReviewScenario: Identifiable {
    var id: String
    var group: String
    var title: String
    var instructions: String
    var target: ReviewTarget

    static let all: [Self] = {
        var rows: [Self] = []
        func dashboard(_ id: String, _ title: String, _ instructions: String,
                       tab: DashboardTab = .overview, fixture: ReviewFixture = .normal, option: String = "") {
            rows.append(.init(id: id, group: tab == .overview ? "Статистика и инспектор" : tab == .models ? "Модели" : "Настройки",
                              title: title, instructions: instructions, target: .dashboard(tab, fixture, option)))
        }
        dashboard("overview", "Статистика · обычный день", "Раскрой состав токенов и список сессий. Проверь сортировку, выбор источника и подсказки при наведении.")
        dashboard("window-chrome", "Окно · скругления и повторное открытие", "Сузь окно до минимума и выбери сессию: окно расширится, скругление левого меню должно остаться согласованным с краем окна. Закрой подробности, снова сузь окно и повтори. Закрой дашборд красной кнопкой или ⌘W и открой через строку меню: края и шапка не должны скачком менять форму.")
        for fixture in [ReviewFixture.many, .empty, .loading, .missing, .failure, .refreshing, .partial, .huge, .zero] {
            dashboard("overview-" + fixture.rawValue, fixture.title,
                      "Проверь заголовки, числа и сообщения. Измени размер окна. Состояние сохраняется до следующего шага; Кнопка обновления использует обычную загрузку. «Успешный ответ источника» снимает ошибку или завершает удерживаемую загрузку.", fixture: fixture,
                      option: fixture == .many ? "expanded" : "")
        }
        dashboard("search", "Поиск и фильтр модели", "Введи модель, проект или ID. Выбери модель и сортировку. Проверь ⌘F, очистку поиска и единственный скролл.", fixture: .many, option: "expanded")
        dashboard("session-links", "Переходы к сессиям", "Проверь поиск, фильтры, раскрытие списка и повторный переход к выбранной сессии.", fixture: .navigation, option: "expanded")
        dashboard("search-empty", "Поиск · ничего не найдено", "Очисти запрос и проверь возвращение строк. Переключи фильтр модели.", option: "no-results")
        dashboard("source", "Один источник", "Выбран Codex. Переключи источники слева и верни «Все источники».", option: "source")
        dashboard("yesterday", "Вчера", "Проверь подпись дня и выбор периода. Выбери «Сегодня» и «Другая дата».", option: "yesterday")
        dashboard("calendar", "Календарь и другая дата", "Листай дни стрелками в капсуле даты, в том числе быстрыми кликами: дата и бюджет должны совпадать, кнопки — оставаться на месте. Дойди до сегодня: правая стрелка отключается. Нажми дату, проверь месяцы, выбор дня, «Сегодня» и Escape. При открытом календаре стрелка дня закрывает его и сразу переключает отчёт.", fixture: .dailyCosts, option: "calendar")
        dashboard("budget", "Бюджет · превышение", "Проверь индикатор бюджета. В настройках можно изменить лимит и вернуться сюда.", option: "budget")
        dashboard("inspector", "Инспектор и окно чата", "Раскрой дополнительную информацию, скопируй ID. Нажми значок чата: откроется настоящий sheet с тестовым разговором. Закрой его и инспектор.", option: "inspector")
        dashboard("inspector-long", "Инспектор · длинные значения", "Раскрой ID и путь проекта. Проверь переносы, копирование и сужение окна.", fixture: .huge, option: "inspector")
        dashboard("models", "Модели · обычные данные", "Проверь логотипы, порядок по стоимости, суммы и раскрытие состава токенов.", tab: .models)
        dashboard("models-excluded", "Исключённая модель", "Включи исключённую модель и проверь изменение сумм. Исключи её снова.", tab: .models, option: "excluded")
        dashboard("models-empty", "Модели · пусто", "Проверь пустое состояние и переход к настройкам исключений.", tab: .models, fixture: .empty)
        dashboard("models-long", "Модели · длинные названия", "Проверь длинную и смешанную модель на узком окне.", tab: .models, fixture: .huge)
        dashboard("provider-sessions", "Логотипы · модели в разных инструментах", "Проверь GLM в Claude Code (Z.AI), префикс tgpt (щит Т-Банка), неизвестные модели (нейтральная иконка) и смешанные сессии. Название инструмента показано отдельно.", fixture: .providers, option: "expanded")
        dashboard("provider-models", "Логотипы · все производители", "Проверь логотипы всех производителей в светлой и тёмной теме. В смешанной строке видны Anthropic, Т-Банк и нейтральная иконка. Сравни одиночный Anthropic и Anthropic в стеке: фон и яркость должны совпадать в обеих темах. GLM сохраняет Z.AI при исключении из итогов.", tab: .models, fixture: .providers)
        dashboard("provider-inspector", "Логотипы · подробности сессии", "Проверь щит с буквой Т и подпись Claude Code. Выбери GLM, смешанную сессию и сессию с неизвестной моделью; логотипы должны совпадать со списком.", fixture: .providers, option: "inspector")
        dashboard("settings", "Настройки · все разделы", "Раскрой подключение и хранилище. Измени язык, интервалы, вид меню и бюджет. Автозапуск здесь только имитируется.", tab: .settings)
        dashboard("settings-cli", "Настройки · ccusage не найден", "Проверь текст ошибки и технические подробности. «Найти автоматически» и «Проверить» используют тестовый сервис; выбор файла открывает системный диалог.", tab: .settings, fixture: .missing)
        dashboard("settings-storage", "Настройки · ошибка хранилища", "Раскрой диагностику и технические подробности. Проверь текст ошибки.", tab: .settings, fixture: .storage)
        dashboard("settings-budget", "Настройки · валидация бюджета", "Введи 0, отрицательное число или текст и нажми «Применить». Затем введи корректную сумму.", tab: .settings, option: "budget")
        for mode in ["onboarding", "off", "ready", "receiving", "waiting", "error", "preview", "conflict", "export"] {
            dashboard("telemetry-" + mode, "Телеметрия Claude · " + mode, "Проверь статус, consent, preview и экспорт. Только временные settings.json, синтетические события и изолированное хранилище.", tab: .settings, option: "telemetry-" + mode)
        }
        let chats: [(String, String, String)] = [
            ("telemetry", "Чат · телеметрия Claude", "Раскрой Телеметрию: сопоставленные запросы, служебный вызов, ошибка, время API и экспорт выбранной сессии."),
            ("normal", "Чат и всплывающие подробности", "Нажимай стоимость и время сообщений. Раскрывай инструменты, исходные записи и полный текст. Проверь копирование и экспорт тестовой истории."),
            ("tools", "Чат · раскрытые инструменты", "Проверь вкладки входа/выхода/исходной записи, копирование и открытие полного текста."),
            ("errors", "Чат · только ошибки", "Проверь подсветку неуспешного инструмента и возврат ко всем сообщениям."),
            ("expensive", "Дорогие обращения", "Нажми обращение, раскрой разбивку токенов, перейди к сообщению."),
            ("analytics", "Аналитика инструментов", "Проверь статистику инструментов, длительности, ошибки и всплывающие пояснения."),
            ("search", "Чат · поиск", "Измени запрос. Проверь подсветку, контекст, фильтры и отсутствие результатов."),
            ("empty", "Чат · пустая история", "Проверь пустой разговор и вкладки аналитики."),
            ("loading", "Чат · загрузка", "Проверь индикатор и недоступные действия. Загрузка удерживается до следующего сценария."),
            ("missing", "Чат · файл не найден", "Проверь ошибку и диалог выбора файла. В режиме проверки пользовательские журналы не читаются."),
            ("partial", "Чат · неполные цены", "Проверь предупреждения и неизвестную стоимость."),
            ("long", "Чат · длинное сообщение", "Открой полный текст длинного сообщения и исходную запись. Проверь sheet, прокрутку и закрытие."),
            ("info", "Чат · информация и экспорт", "Раскрой сведения о тестовом журнале. Проверь экспорт через системный диалог сохранения.")
        ]
        for (id, title, instructions) in chats {
            rows.append(.init(id: "chat-" + id, group: "История чата", title: title, instructions: instructions, target: .chat(id)))
        }
        for fixture in [ReviewFixture.normal, .empty, .loading, .missing, .failure, .refreshing, .stale, .partial, .huge, .zero, .gaps] {
            rows.append(.init(id: "menu-" + fixture.rawValue, group: "Строка меню", title: fixture.title,
                              instructions: "Открыт настоящий popover основного приложения в строке меню. Проверь размеры, кнопки, Escape, правый клик по значку и повторное открытие. «Показать окно» открывает его снова.",
                              target: .menu(fixture, fixture == .gaps ? .trend : .summary, false)))
        }
        rows.append(.init(id: "menu-budget", group: "Строка меню", title: "Динамика и бюджет", instructions: "Проверь график за неделю, лимит и кнопки перехода.", target: .menu(.normal, .trend, true)))
        for variant in UsageWidgetVariant.allCases {
            for fixture in [ReviewFixture.normal, .empty, .loading, .failure, .stale, .partial, .huge, .gaps, .storage] {
                rows.append(.init(id: "widget-\(variant.rawValue)-\(fixture.rawValue)", group: "Виджеты", title: "\(variant.title) · \(fixture.title)",
                                  instructions: "Проверь все три размера. Это живое SwiftUI-содержимое; системную подложку, размещение и переходы WidgetKit нужно дополнительно проверить на рабочем столе в обычном приложении.",
                                  target: .widgets(variant, fixture)))
            }
        }
        let steps = ["Статистика", "Настройки", "Модели", "Снова статистика", "Другая дата", "Инспектор", "Закрыть инспектор"]
        for (index, title) in steps.enumerated() {
            rows.append(.init(id: "transition-\(index)", group: "Переходы без пересоздания окна", title: "\(index + 1). \(title)",
                              instructions: "Иди по шагам кнопкой «Далее». Окно и хранилище сохраняются. Следи за шапкой: кнопки не должны дублироваться. Можно вручную повторять переходы и менять ширину.", target: .transition(index)))
        }
        return rows
    }()
}

struct ReviewRecord: Codable {
    var status = "unreviewed"
    var notes = ""
    var updatedAt = Date()
    var scenario: String
    var language: String
    var appearance: String
    var size: String
}

struct ReviewReport: Codable {
    var version = 1
    var records: [String: ReviewRecord] = [:]
}
