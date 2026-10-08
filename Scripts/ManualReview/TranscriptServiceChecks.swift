#if MANUAL_REVIEW
import AppKit
import SwiftUI

struct ReviewTranscriptServiceProbe: NSViewRepresentable {
    var eventID: String
    var kind: TranscriptServiceEvent.Kind
    var role: String
    var expanded: Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.eventID = eventID; view.kind = kind; view.role = role; view.expanded = expanded
    }
    final class Probe: NSView {
        var eventID = ""
        var kind = TranscriptServiceEvent.Kind.compaction
        var role = ""
        var expanded = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

#endif

import Foundation

enum ReviewServiceTranscript {
    static var sample: SessionTranscript {
        let lines = #"""
        {"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":184320,"postTokens":12480,"durationMs":8420}}
        {"type":"system","subtype":"api_error","cause":{"code":"ECONNRESET","message":"Connection interrupted while receiving the response."},"retryAttempt":2,"maxRetries":10,"retryInMs":1500}
        {"type":"attachment","attachment":{"type":"hook_blocking_error","hookEvent":"Stop","hookName":"verify-tests","blockingError":{"command":"bash Scripts/check.sh","blockingError":"Run the test suite before completing this task."}}}
        {"type":"attachment","attachment":{"type":"hook_additional_context","hookEvent":"PostToolUse:Edit","hookName":"project-guidance","content":["This file is generated. Edit src/schema.ts and regenerate the output.","Keep the existing public API and document any behavior changes."]}}
        {"type":"attachment","attachment":{"type":"diagnostics","files":[{"filePath":"Sources/SessionStore.swift","diagnostics":[{"severity":"Warning","message":"Immutable value 'result' was never used; consider replacing it with '_' or removing it.","source":"Swift","range":{"start":{"line":41,"character":8}},"code":{"value":"unused-value","target":{"path":"/diagnostics/unused"}}}]}]}}
        {"type":"system","subtype":"turn_duration","durationMs":18000}
        {"type":"attachment","attachment":{"type":"hook_success","hookName":"format"}}
        """#
        var decoder = TranscriptDecoder(source: "claude")
        decoder.origin = "review-service-events.jsonl"
        let start = UsageDay().date.addingTimeInterval(12 * 3600 + 40 * 60)
        for (index, line) in lines.split(separator: "\n").enumerated() {
            var record = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            record["timestamp"] = start.addingTimeInterval(Double(index) * 10).ISO8601Format()
            if index == 3 {
                var attachment = record["attachment"] as! [String: Any]
                attachment["content"] = (attachment["content"] as! [String]) + [String(repeating: "Preserve the user's changes.\n", count: 70) + "review-context-end"]
                record["attachment"] = attachment
            }
            decoder.append(record)
        }
        return .init(events: decoder.finish())
    }
}

#if MANUAL_REVIEW
@MainActor enum TranscriptServiceChecks {
    static func run(_ review: ManualReviewController) async throws {
        guard let window = review.dashboard else { return }
        for language in [InterfaceLanguage.russian, .english] {
            for appearance in [ReviewAppearance.light, .dark] {
                review.language = language; review.appearance = appearance; review.size = .compact
                review.changePresentation()
                try await ReviewCheck.select("chat-service-events", in: review)
                try await ReviewCheck.wait("Missing readable service rows in production chat") { toggles(window).count == 5 }
                for probe in toggles(window) {
                    try ReviewCheck.require(!probe.expanded, "Service details did not start folded")
                    guard let sheet = probe.window, let host = sheet.contentView else { continue }
                    let rect = probe.convert(probe.bounds, to: host)
                    try ReviewCheck.require(rect.minX >= 0 && rect.maxX <= host.bounds.width && rect.height >= 28,
                                            "Service event escaped the compact sheet")
                }
                guard let context = toggles(window).first(where: { $0.kind == .hookContext }) else { throw CocoaError(.validationMissingMandatoryProperty) }
                try await click(context)
                try await ReviewCheck.wait("Hook instructions did not expand") { context.expanded && control("full", kind: .hookContext, in: window) != nil }
                try await click(control("full", kind: .hookContext, in: window)!)
                try await ReviewCheck.wait("Full hook context did not reach the native reader") {
                    reader(in: window)?.string.contains("review-context-end") == true
                }
                try await closeReader(window)
                try await click(control("raw", kind: .hookContext, in: window)!)
                try await ReviewCheck.wait("Source JSON not reachable from service row") {
                    reader(in: window)?.string.contains("hook_additional_context") == true
                }
                try await closeReader(window)
                try await click(context)
                try await ReviewCheck.wait("Hook instructions did not collapse") { !context.expanded }
                guard let diagnostics = toggles(window).first(where: { $0.kind == .diagnostics }) else { throw CocoaError(.validationMissingMandatoryProperty) }
                try await click(diagnostics)
                try await ReviewCheck.wait("Editor diagnostics did not expand") { diagnostics.expanded && control("full", kind: .diagnostics, in: window) != nil }
                try await click(control("full", kind: .diagnostics, in: window)!)
                try await ReviewCheck.wait("File and diagnostic code missing from native reader") {
                    reader(in: window)?.string.contains("Sources/SessionStore.swift") == true
                        && reader(in: window)?.string.contains("unused-value") == true
                }
                try await closeReader(window)
                try await ReviewCheck.select("chat-service-errors", in: review)
                try await ReviewCheck.wait("Only errors lost API/hook failures or included informational events") {
                    let rows = toggles(window)
                    // SwiftUI may recycle native hosts in a different subview
                    // order from the visual LazyVStack order.
                    return rows.count == 2 && Set(rows.map(\.kind)) == [.apiError, .hookBlocked]
                }
                print("PASS Service-event rows, native disclosure/full reader/JSON and error filter in \(language.rawValue)/\(appearance.rawValue)")
            }
        }
    }
    private static func toggles(_ window: NSWindow) -> [ReviewTranscriptServiceProbe.Probe] {
        guard let host = window.attachedSheet?.contentView else { return [] }
        return ReviewCheck.views(ReviewTranscriptServiceProbe.Probe.self, in: host).filter { $0.role == "toggle" && !$0.isHiddenOrHasHiddenAncestor }
    }
    private static func control(_ role: String, kind: TranscriptServiceEvent.Kind, in window: NSWindow) -> ReviewTranscriptServiceProbe.Probe? {
        guard let host = window.attachedSheet?.contentView else { return nil }
        return ReviewCheck.views(ReviewTranscriptServiceProbe.Probe.self, in: host).first { $0.role == role && $0.kind == kind && !$0.isHiddenOrHasHiddenAncestor }
    }
    private static func reader(in window: NSWindow) -> NSTextView? {
        guard let host = window.attachedSheet?.attachedSheet?.contentView else { return nil }
        return ReviewCheck.views(NSTextView.self, in: host).first
    }
    private static func closeReader(_ window: NSWindow) async throws {
        guard let sheet = window.attachedSheet?.attachedSheet,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { throw CocoaError(.validationMissingMandatoryProperty) }
        sheet.makeKeyAndOrderFront(nil)
        _ = sheet.performKeyEquivalent(with: event)
        try await ReviewCheck.wait("Native reader did not close") { window.attachedSheet?.attachedSheet == nil }
    }
    private static func click(_ view: NSView) async throws {
        guard let window = view.window else { throw CocoaError(.validationMissingMandatoryProperty) }
        view.scrollToVisible(view.bounds)
        window.makeKeyAndOrderFront(nil)
        try await ReviewCheck.settle()
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }
}
#endif
