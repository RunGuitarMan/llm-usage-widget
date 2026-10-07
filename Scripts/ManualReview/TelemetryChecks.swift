import AppKit
import SwiftUI

/// Read-only geometry/state probe attached to the actual SwiftUI controls. It
/// exists only in runtime review; it never hosts a product view or window.
struct TelemetryReviewProbe: NSViewRepresentable {
    var kind: String
    var text: String = ""
    var value = 0
    var action: (() -> Void)?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.kind = kind; view.text = text; view.value = value; view.action = action }
    final class Probe: NSView {
        var kind = ""; var text = ""; var value = 0; var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor enum TelemetryReview {
    static let sid = "11111111-1111-4111-8111-111111111111"
    static func transcript() -> SessionTranscript {
        var result = TranscriptPreview.sample
        for i in result.requests.indices {
            let usage = result.requests[i].usage
            result.requests[i].billing.tokens = ["input_tokens": usage.input, "output_tokens": usage.output,
                "cache_read_input_tokens": usage.cacheRead, "cache_creation_input_tokens": usage.cacheCreate]
            result.requests[i].telemetryIdentity = .init(sessionID: sid, requestID: "review-request-\(i)")
        }
        return result
    }
    static func configure(_ coordinator: ClaudeTelemetryCoordinator, mode: String) async throws {
        guard coordinator.isolated, let root = coordinator.isolationRoot else { throw TelemetryFailure.unsafePath }
        coordinator.presentsOnboarding = false; coordinator.presentsExport = false; coordinator.cancelSetup()
        await coordinator.setEnabled(false)
        try await coordinator.store.delete()
        let parent = root.appendingPathComponent(".claude")
        try TelemetryFiles.createDirectory(parent)
        let url = parent.appendingPathComponent("settings.json")
        coordinator.settingsURL = url
        let config = mode == "conflict" ? "{\"env\":{\"OTEL_LOGS_EXPORTER\":\"console\"},\"permissions\":{}}" : "{\"permissions\":{},\"hooks\":{},\"env\":{\"SYNTHETIC_PROXY\":\"fixture\"}}"
        try TelemetryFiles.atomic(Data(config.utf8), to: url)
        if mode == "onboarding" { coordinator.presentsOnboarding = true; return }
        if mode == "preview" || mode == "conflict" { await coordinator.preparePreview(); return }
        if mode == "off" { return }
        // Listener-only is an explicit review action; it never edits the fixture env.
        await coordinator.useListenerOnly()
        if mode == "ready" { return }
        if mode == "error" { coordinator.failure = .storage; return }
        let now = mode == "waiting" ? Date().addingTimeInterval(-90) : Date()
        var events = transcript().requests.enumerated().map { index, request -> ClaudeTelemetryEvent in
            var event = ClaudeTelemetryEvent(sessionID: sid, kind: .apiRequest, requestID: "review-request-\(index)",
                                              timestamp: now.addingTimeInterval(Double(index)), receivedAt: now)
            event.model = request.model; event.durationMS = 1200; event.input = request.billing.tokens["input_tokens"]
            event.output = request.billing.tokens["output_tokens"]; event.cacheRead = request.billing.tokens["cache_read_input_tokens"]
            event.cacheWrite = request.billing.tokens["cache_creation_input_tokens"]
            event.costUSD = String(request.usage.cost); event.source = .main
            return event
        }
        var service = ClaudeTelemetryEvent(sessionID: sid, kind: .apiRequest, requestID: "review-title", timestamp: now, receivedAt: now)
        service.source = .title; service.model = "claude-sonnet-4-6"; service.input = 1735; service.output = 47
        service.cacheRead = 0; service.cacheWrite = 0; service.durationMS = 600; service.costUSD = "0.00394"
        events.append(service)
        var failed = ClaudeTelemetryEvent(sessionID: sid, kind: .apiError, requestID: "review-error", timestamp: now, receivedAt: now)
        failed.errorCategory = .rateLimit; failed.statusCode = 429; failed.attempt = 2; failed.durationMS = 300
        events.append(failed)
        try await coordinator.store.accept(.init(events: events), now: now)
        await coordinator.refresh()
        if mode == "history" { await coordinator.setEnabled(false) }
        if mode == "export" { coordinator.exportSessions([sid]) }
    }
    static func probes(_ window: NSWindow?, kind: String) -> [TelemetryReviewProbe.Probe] {
        guard let window, let content = window.contentView else { return [] }
        return ReviewCheck.views(TelemetryReviewProbe.Probe.self, in: content).filter { $0.kind == kind && $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
    }
    static func run(_ review: ManualReviewController) async throws {
        guard let window = review.dashboard else { return }
        var coordinator: ClaudeTelemetryCoordinator { review.store.telemetry }
        try ReviewCheck.require(coordinator.isolated, "Review telemetry reached live paths")
        for language in [InterfaceLanguage.russian, .english] {
            for appearance in [ReviewAppearance.light, .dark] {
                review.language = language; review.appearance = appearance; review.size = .compact; review.changePresentation()
                try await ReviewCheck.select("telemetry-onboarding", in: review)
                try await ReviewCheck.wait("Onboarding is absent from production sheet") { !probes(window.attachedSheet, kind: "onboarding").isEmpty }
                coordinator.dismissOnboarding()
                try await ReviewCheck.wait("Onboarding did not dismiss") { window.attachedSheet == nil }
                try await ReviewCheck.select("telemetry-ready", in: review)
                try await ReviewCheck.wait("Telemetry status is absent from production Settings") {
                    probes(window, kind: "status").contains { $0.text == coordinator.statusText }
                }
                try ReviewCheck.require(coordinator.status == .ready && coordinator.snapshot.coverage.lastAPIEvent == nil, "Empty receiver claims API activity")
                for (scenario, status) in [("telemetry-receiving", ClaudeTelemetryCoordinator.Status.receiving), ("telemetry-waiting", .waiting), ("telemetry-error", .failure), ("telemetry-off", .off)] {
                    try await ReviewCheck.select(scenario, in: review)
                    try ReviewCheck.require(coordinator.status == status, "Incorrect production telemetry status: \(scenario)")
                }
                try await ReviewCheck.select("telemetry-preview", in: review)
                try await ReviewCheck.wait("Setup bypassed production sheet") { window.attachedSheet != nil && !probes(window.attachedSheet, kind: "setup").isEmpty }
                let config = coordinator.settingsURL
                let before = try Data(contentsOf: config)
                let originalFiles = try FileManager.default.contentsOfDirectory(atPath: config.deletingLastPathComponent().path)
                try ReviewCheck.require(coordinator.preview?.canApply == true && probes(window.attachedSheet, kind: "setup").first?.value == 1, "Consent control disabled for safe additions")
                coordinator.cancelSetup()
                try await ReviewCheck.wait("Setup did not close") { window.attachedSheet == nil }
                try ReviewCheck.require(try Data(contentsOf: config) == before && FileManager.default.contentsOfDirectory(atPath: config.deletingLastPathComponent().path) == originalFiles, "Cancelled preview wrote fixture")
                try await ReviewCheck.select("telemetry-conflict", in: review)
                try await ReviewCheck.wait("Conflict setup missing") { !probes(window.attachedSheet, kind: "setup").isEmpty }
                try ReviewCheck.require(probes(window.attachedSheet, kind: "setup").first?.value == 0, "Conflicting setup enables consent")
                coordinator.cancelSetup(); try await ReviewCheck.wait("Conflict sheet did not close") { window.attachedSheet == nil }
                try await ReviewCheck.select("telemetry-export", in: review)
                try await ReviewCheck.wait("Export preview missing") { !probes(window.attachedSheet, kind: "export").isEmpty }
                try ReviewCheck.require(probes(window.attachedSheet, kind: "export").first!.value > 0, "Export has no selected API events")
                coordinator.presentsExport = false; try await ReviewCheck.wait("Export sheet did not close") { window.attachedSheet == nil }
                try await ReviewCheck.select("chat-telemetry", in: review)
                try await ReviewCheck.wait("Session telemetry missing in real chat") { !probes(window.attachedSheet, kind: "chat").isEmpty }
                probes(window.attachedSheet, kind: "chat").first?.action?()
                try await ReviewCheck.settle()
                try await ReviewCheck.wait("Chat failed ID correlation") { probes(window.attachedSheet, kind: "chat").first?.value == 3 }
                if let sheet = window.attachedSheet { try await ReviewCheck.resize(sheet, width: 720, height: 700) }
                review.store.requestReviewChat(false); try await ReviewCheck.wait("Chat did not dismiss") { window.attachedSheet == nil }
                print("PASS Claude telemetry settings/status/consent/export/chat in production UI: \(language.rawValue)/\(appearance.rawValue)")
            }
        }
        try await ReviewCheck.select("overview", in: review)
    }
}
