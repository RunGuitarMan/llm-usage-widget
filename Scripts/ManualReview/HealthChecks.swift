import AppKit
import SwiftUI

/// Read the data actually bound to production controls, without rebuilding any
/// window or substituting a button action. Clicks below go through native events.
struct ReviewHealthProbe: NSViewRepresentable {
    var problems: [UsageProblem]
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.problems = problems }
    final class Probe: NSView {
        var problems: [UsageProblem] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct ReviewHealthControlProbe: NSViewRepresentable {
    var name: String
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.name = name }
    final class Probe: NSView {
        var name = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor enum HealthChecks {
    static func run(_ review: ManualReviewController) async throws {
        guard let window = review.dashboard else { return }
        let store = review.store
        for language in [InterfaceLanguage.russian, .english] {
            for appearance in [ReviewAppearance.light, .dark] {
                review.language = language
                review.appearance = appearance
                review.size = .compact
                review.changePresentation()
                try await ReviewCheck.select("overview-stale", in: review)
                try ReviewCheck.require(store.error == nil && store.problems().map(\.reference.kind) == [.stale], "Pure stale fixture: error=\(String(describing: store.error)), problems=\(store.problems().map(\.id))")
                try await ReviewCheck.wait("Missing stale banner in production dashboard") { probes(in: window).count == 1 }
                try ReviewCheck.require(probes(in: window)[0].problems == store.problems(), "Dashboard diverged from shared problems")
                try await click(probes(in: window)[0])
                try await ReviewCheck.wait("Banner click did not open the production problem sheet") { control("details", in: window.attachedSheet) != nil }
                review.service.releaseResponse()
                try await click(control("retry", in: window.attachedSheet)!)
                try await ReviewCheck.wait("Successful retry did not explain resolved problem") { control("resolved", in: window.attachedSheet) != nil && store.problems().isEmpty }
                try await closeSheet(window)

                try await ReviewCheck.select("menu-multiple", in: review)
                try await ReviewCheck.wait("Popover did not bind the shared problem list") {
                    menuProbe(excluding: window)?.problems == store.problems(for: store.selectedDay, includeHidden: false)
                }
                guard let menu = menuProbe(excluding: window) else { throw CocoaError(.validationMissingMandatoryProperty) }
                try ReviewCheck.require(menu.problems.count >= 3, "Popover masked simultaneous problems")
                try await click(menu)
                try await ReviewCheck.wait("Menu problem did not open its sheet: requested=\(String(describing: store.presentedProblem)), menuVisible=\(menu.window?.isVisible ?? false), sheet=\(String(describing: window.attachedSheet))") { control("details", in: window.attachedSheet) != nil }
                try await closeSheet(window)

                try await ReviewCheck.select("overview-partial", in: review)
                try await ReviewCheck.wait("Missing partial-cost control") { control("partial-cost", in: window) != nil }
                try ReviewCheck.require(probes(in: window).isEmpty, "Partial cost still shows a dashboard banner")
                try await click(control("partial-cost", in: window)!)
                try await ReviewCheck.wait("Partial-cost details did not open") { control("retry", in: window.attachedSheet) != nil }
                try await click(control("retry", in: window.attachedSheet)!)
                try await ReviewCheck.wait("Partial retry has no visible result") {
                    control("result", in: window.attachedSheet) != nil && store.recoveryResult?.incomplete == 1
                }
                try await click(control("hide", in: window.attachedSheet)!)
                try await ReviewCheck.wait("Hide did not dismiss the cost notice") {
                    window.attachedSheet == nil && control("partial-cost", in: window) == nil
                }
                await store.refresh()
                try ReviewCheck.require(control("partial-cost", in: window) == nil, "Refresh resurrected hidden cost notice")
                try ReviewCheck.require(WidgetPresentation(status: store.presentationStatus).problems(at: Date()).allSatisfy { $0.reference.kind != .cost }, "Widget ignored hidden cost notice")

                try await ReviewCheck.select("overview", in: review)
                review.service.usePartialHistory()
                let today = store.selectedDay
                for offset in 1...10 { await store.selectCustomDate(today.adding(days: -offset).date) }
                try await ReviewCheck.wait("Historical partial-cost control missing") { control("partial-cost", in: window) != nil }
                try await click(control("partial-cost", in: window)!)
                try await ReviewCheck.wait("Historical details missing") { control("details", in: window.attachedSheet) != nil }
                try ReviewCheck.require(store.presentedProblem?.day == today.adding(days: -10), "Partial-cost click opened the wrong date")
                try await closeSheet(window)
                await store.selectCustomDate(today.date)
                try await ReviewCheck.wait("Returning to today kept a historical notice") {
                    control("partial-cost", in: window) == nil && probes(in: window).isEmpty
                }
                try ReviewCheck.require(WidgetPresentation(status: store.presentationStatus).problems(at: Date()).isEmpty, "Browsing dates contaminated widget diagnostics")
                store.navigate(.settings)
                try await ReviewCheck.settle()
                try ReviewCheck.require(probes(in: window).isEmpty, "Settings show a report banner")
                print("PASS Native dated diagnostics, retry outcome, persistent dismissal and ten-day isolation in \(language.rawValue)/\(appearance.rawValue)")
            }
        }
        try await ReviewCheck.select("overview", in: review)
    }

    private static func probes(in window: NSWindow) -> [ReviewHealthProbe.Probe] {
        guard let host = window.contentView else { return [] }
        return ReviewCheck.views(ReviewHealthProbe.Probe.self, in: host).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
        }
    }
    private static func menuProbe(excluding window: NSWindow) -> ReviewHealthProbe.Probe? {
        NSApp.windows.filter { $0 !== window && $0.isVisible && $0.identifier?.rawValue != "review-widgets" }
            .flatMap { probes(in: $0) }.first
    }
    private static func widgetWindow() -> NSWindow? { NSApp.windows.first { $0.identifier?.rawValue == "review-widgets" } }
    private static func control(_ name: String, in window: NSWindow?) -> ReviewHealthControlProbe.Probe? {
        guard let host = window?.contentView else { return nil }
        return ReviewCheck.views(ReviewHealthControlProbe.Probe.self, in: host).first { $0.name == name && !$0.isHiddenOrHasHiddenAncestor }
    }
    private static func closeSheet(_ window: NSWindow) async throws {
        guard let close = control("close", in: window.attachedSheet) else { throw CocoaError(.validationMissingMandatoryProperty) }
        try await click(close)
        try await ReviewCheck.wait("Problem sheet did not dismiss") { window.attachedSheet == nil }
    }
    private static func click(_ view: NSView) async throws {
        guard let window = view.window else { throw CocoaError(.validationMissingMandatoryProperty) }
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
