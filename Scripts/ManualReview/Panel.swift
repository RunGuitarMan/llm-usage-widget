#if MANUAL_REVIEW
import AppKit
import SwiftUI

struct ManualReviewPanel: View {
    @ObservedObject var review: ManualReviewController
    @State private var search = ""
    @State private var group = "Все разделы"
    private var groups: [String] { ReviewScenario.all.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } } }
    private var filtered: [ReviewScenario] {
        ReviewScenario.all.filter { (group == "Все разделы" || group == $0.group)
            && (search.isEmpty || ($0.title + " " + $0.instructions).localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ручная проверка UI").font(.title2.bold())
                    Text("\(review.reviewedCount) / \(ReviewScenario.all.count) проверено · проблем: \(review.problemCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { review.showCurrent() } label: { Image(systemName: "macwindow") }
                    .help("Показать проверяемое окно или popover")
            }
            VStack(spacing: 8) {
                HStack {
                    Text("Язык").fixedSize()
                    Picker("Язык", selection: $review.language) {
                        Text("RU").tag(InterfaceLanguage.russian)
                        Text("EN").tag(InterfaceLanguage.english)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
                    Text("Тема").fixedSize()
                    Picker("Тема", selection: $review.appearance) {
                        ForEach(ReviewAppearance.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                HStack {
                    Picker("Размер", selection: $review.size) {
                        ForEach(ReviewSize.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Показать окно") { review.showCurrent() }
                }
            }
            Text("Сборка \(review.buildID) · основное приложение").font(.caption2).foregroundStyle(.secondary)
            Text("Отметки и заметки отдельные для каждого языка, темы и размера.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Picker("Раздел", selection: $group) {
                Text("Все разделы").tag("Все разделы")
                ForEach(groups, id: \.self) { Text($0).tag($0) }
            }
            TextField("Найти экран или состояние", text: $search)
                .textFieldStyle(.roundedBorder)
            List(selection: Binding<String?>(get: { review.selectedID }, set: { if let id = $0 { review.select(id) } })) {
                ForEach(groups, id: \.self) { name in
                    let rows = filtered.filter { $0.group == name }
                    if !rows.isEmpty {
                        Section(name) {
                            ForEach(rows) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: symbol(review.report.records[review.key(for: item.id)]?.status))
                                        .foregroundStyle(color(review.report.records[review.key(for: item.id)]?.status))
                                    Text(item.title).font(.system(size: 12)).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 3).tag(item.id)
                            }
                        }
                    }
                }
            }.listStyle(.inset).frame(minHeight: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(review.index + 1). \(review.scenario.title)").font(.headline)
                ScrollView { Text(review.scenario.instructions).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 45)
            }
            HStack {
                Button("Назад") { review.move(-1) }.disabled(review.index == 0)
                Button("Сбросить состояние") { review.select(review.selectedID) }
                Spacer(minLength: 0)
                Button("Далее") { review.move(1) }.disabled(review.index == ReviewScenario.all.count - 1)
            }
            Button("Успешный ответ источника") { review.recoverSource() }.disabled(review.preparing)
            HStack {
                Button { review.save(status: "passed") } label: { Label("Проверено", systemImage: "checkmark.circle") }
                    .tint(review.currentRecord.status == "passed" ? .green : .accentColor)
                Button { review.save(status: "issue") } label: { Label("Проблема", systemImage: "exclamationmark.bubble") }
                    .tint(review.currentRecord.status == "issue" ? .orange : .accentColor)
                Button("Пропуск") { review.save(status: "skipped") }
            }.buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 5) {
                Text("Заметки · сохраняются автоматически").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { review.currentRecord.notes }, set: { review.save(notes: $0) }))
                    .font(.system(size: 12)).frame(height: 45)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            if let error = review.persistenceError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("Изолированные данные · без чтения журналов").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Отчёт") { NSWorkspace.shared.open(review.reportURL.deletingLastPathComponent()) }.font(.caption)
            }
        }
        .padding(12).frame(minWidth: 490, idealWidth: 500, minHeight: 650)
        .background { ReviewWindowConnection { review.panel = $0 } }
        .onChange(of: review.language) { _, _ in review.changePresentation() }
        .onChange(of: review.appearance) { _, _ in review.changePresentation() }
        .onChange(of: review.size) { _, _ in review.changePresentation() }
    }

    private func symbol(_ status: String?) -> String {
        switch status { case "passed": return "checkmark.circle.fill"; case "issue": return "exclamationmark.circle.fill"; case "skipped": return "arrow.right.circle"; default: return "circle" }
    }
    private func color(_ status: String?) -> Color {
        switch status { case "passed": return .green; case "issue": return .orange; default: return .secondary }
    }
}


#endif
