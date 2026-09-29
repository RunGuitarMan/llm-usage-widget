import Foundation
import Combine

/// Both lists use the same cancellation and publication rules. Expensive work
/// never inherits MainActor, and only the newest request can publish its result.
@MainActor
final class SearchResults<Input: Sendable, Output: Sendable>: ObservableObject {
    @Published private(set) var value: Output
    @Published private(set) var completedInput: Input?
    @Published private(set) var isSearching = false
    private var generation = 0
    private var worker: Task<Output, Error>?
    private let evaluate: @Sendable (Input) throws -> Output

    init(initial: Output, evaluate: @escaping @Sendable (Input) throws -> Output) {
        value = initial
        self.evaluate = evaluate
    }

    deinit { worker?.cancel() }

    func update(_ input: Input, delay: Duration = .milliseconds(120)) async {
        generation += 1
        let revision = generation
        worker?.cancel()
        isSearching = true
        let evaluate = evaluate
        let task = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            let output = try evaluate(input)
            try Task.checkCancellation()
            return output
        }
        worker = task
        defer {
            if generation == revision { worker = nil; isSearching = false }
        }
        do {
            let output = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: { task.cancel() })
            guard revision == generation, !Task.isCancelled else { return }
            completedInput = input
            value = output
        } catch { /* Cancellation leaves the last completed result visible. */ }
    }
}

struct TranscriptRow: Identifiable, Sendable {
    var events: [TranscriptEvent]
    var id: String { events[0].id }
    var isContext: Bool { events[0].kind == .context }
}

struct TranscriptSearchRequest: Equatable, Sendable {
    var transcript: SessionTranscript?
    var query = ""
    var showContext = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.transcript?.id == rhs.transcript?.id && lhs.query == rhs.query && lhs.showContext == rhs.showContext
    }
}

struct TranscriptSearchResult: Sendable {
    var rows: [TranscriptRow] = []
    var eventCount = 0

    static func evaluate(_ request: TranscriptSearchRequest) throws -> Self {
        var result = Self()
        var recordMatches: [UUID: Bool] = [:]
        for event in request.transcript?.events ?? [] {
            try Task.checkCancellation()
            guard request.showContext || event.kind != .context || !request.query.isEmpty else { continue }
            if !request.query.isEmpty {
                var matches = [event.title, event.text, event.input, event.output]
                    .contains { $0.localizedCaseInsensitiveContains(request.query) }
                if !matches {
                    for record in event.records {
                        try Task.checkCancellation()
                        let found: Bool
                        if let cached = recordMatches[record.id] { found = cached }
                        else {
                            found = record.text.localizedCaseInsensitiveContains(request.query)
                            recordMatches[record.id] = found
                        }
                        if found { matches = true; break }
                    }
                }
                guard matches else { continue }
            }
            result.eventCount += 1
            if event.kind == .context, result.rows.last?.isContext == true {
                result.rows[result.rows.count - 1].events.append(event)
            } else { result.rows.append(TranscriptRow(events: [event])) }
        }
        return result
    }
}

struct SessionSearchRequest: Equatable, Sendable {
    var sessions: [UsageSession]
    var source = ""
    var query = ""
    var model = ""
    var sort = SessionSort.cost
}

struct SessionSearchResult: Sendable {
    var sessions: [UsageSession] = []
    var total = TokenUsage.zero

    static func evaluate(_ request: SessionSearchRequest) throws -> Self {
        var result = Self()
        for session in request.sessions {
            try Task.checkCancellation()
            guard request.source.isEmpty || session.sourceID == request.source,
                  request.model.isEmpty || session.models.contains(request.model) else { continue }
            guard request.query.isEmpty || session.rawID.localizedCaseInsensitiveContains(request.query)
                || session.modelLabel.localizedCaseInsensitiveContains(request.query)
                || session.sourceLabel.localizedCaseInsensitiveContains(request.query)
                || session.projectPath?.localizedCaseInsensitiveContains(request.query) == true else { continue }
            result.sessions.append(session)
            result.total = result.total + session.usage
        }
        try Task.checkCancellation()
        result.sessions = request.sort.sorted(result.sessions)
        return result
    }
}
