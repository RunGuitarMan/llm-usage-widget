import SwiftUI

/// A quiet timeline annotation: the explanation stays visible, while lengthy
/// hook instructions, diagnostics and source records open on demand.
struct TranscriptServiceRow: View {
    var event: TranscriptEvent
    var service: TranscriptServiceEvent
    var timestamp: String?
    var query: String
    var copy: (String) -> Void
    var open: (String, String, Bool) -> Void
    @State private var expanded = false

    private var color: Color {
        if event.isError { return .orange }
        switch service.kind {
        case .compaction: return .teal
        case .hookContext: return .indigo
        default: return .secondary
        }
    }
    private var symbol: String {
        switch service.kind {
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .apiError: return "arrow.triangle.2.circlepath"
        case .hookBlocked: return "hand.raised"
        case .hookError: return "exclamationmark.circle"
        case .hookContext: return "text.badge.plus"
        case .diagnostics: return "stethoscope"
        }
    }
    private var detailText: String {
        ([service.title] + service.facts + [event.text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var preview: TranscriptTextPreview { TranscriptTextPreview(event.text) }
    private var summary: String { preview.text.split(whereSeparator: \.isNewline).joined(separator: " · ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                        .frame(width: 28, height: 28)
                        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(service.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if let timestamp { Text(timestamp).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize() }
                        }
                        if !service.facts.isEmpty {
                            Text(service.facts.joined(separator: " · "))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                                .lineLimit(2).help(service.facts.joined(separator: "\n"))
                        }
                        if !service.isSupplementary, service.kind != .compaction, !event.text.isEmpty, !expanded {
                            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if service.isSupplementary, !expanded {
                            Text(L10n.text("Показать содержимое"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: 10, height: 16)
                }
                .padding(12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(service.title)
            .accessibilityValue(expanded ? L10n.text("Развёрнуто") : L10n.text("Свёрнуто"))
            .accessibilityHint((service.facts + (service.isSupplementary ? [] : [summary])).joined(separator: ". "))
            #if MANUAL_REVIEW
            .background(ReviewTranscriptServiceProbe(eventID: event.id, kind: service.kind, role: "toggle", expanded: expanded))
            #endif

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().overlay(color.opacity(0.08))
                    if !event.text.isEmpty {
                        Text(preview.text).font(.system(size: 12, design: service.kind == .diagnostics ? .monospaced : .default))
                            .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if service.facts.isEmpty {
                        Text(L10n.text("Подробности доступны в исходной записи"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let origin = event.origin {
                        Text(origin).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(origin)
                    }
                    HStack(spacing: 14) {
                        Button { open(service.title, detailText, service.kind == .diagnostics) } label: {
                            Label(L10n.text("Прочитать полностью"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        #if MANUAL_REVIEW
                        .background(ReviewTranscriptServiceProbe(eventID: event.id, kind: service.kind, role: "full", expanded: expanded))
                        #endif
                        Button { open(L10n.text("Исходная запись"), event.raw, true) } label: {
                            Label("JSON", systemImage: "curlybraces")
                        }.help(L10n.text("Исходная запись")).accessibilityLabel(L10n.text("Исходная запись"))
                        #if MANUAL_REVIEW
                        .background(ReviewTranscriptServiceProbe(eventID: event.id, kind: service.kind, role: "raw", expanded: expanded))
                        #endif
                        Spacer(minLength: 0)
                        Button { copy(detailText) } label: { Image(systemName: "doc.on.doc") }
                            .help(L10n.text("Скопировать сообщение")).accessibilityLabel(L10n.text("Скопировать сообщение"))
                    }.font(.system(size: 11)).buttonStyle(.borderless)
                    if !query.isEmpty, !preview.text.localizedCaseInsensitiveContains(query) {
                        Button(L10n.text("Совпадение в полном содержимом")) {
                            open(service.title, event.searchableText, true)
                        }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .background(color.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(event.isError ? 0.3 : 0.16)))
        .onAppear { if !query.isEmpty { expanded = true } }
        .onChange(of: query) { _, value in if !value.isEmpty { expanded = true } }
    }
}
