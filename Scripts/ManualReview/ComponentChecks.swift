import AppKit
import SwiftUI

// Component-only checks run in the same app process and never create a window.
@MainActor private final class TrackingPopover: NSPopover {
    var presented = false
    var positioningChanges = 0
    override var isShown: Bool { presented }
    override var positioningRect: NSRect {
        get { super.positioningRect }
        set { positioningChanges += 1; super.positioningRect = newValue }
    }
}

@MainActor enum ComponentChecks {
    static func run(store: UsageStore) async throws {
        for language in [InterfaceLanguage.english, .russian] {
            store.interfaceLanguage = language
            let transcript = TranscriptPreview.sample
            for timing in [transcript.events[0].timing!, TranscriptTiming(kind: .processing),
                           TranscriptTiming(kind: .tool, duration: 0.25, evidence: .recorded)] {
                let details = NSHostingView(rootView: TranscriptTimingDetails(timing: timing, timezone: "UTC")
                    .padding(18).frame(width: 340))
                let size = details.fittingSize
                try ReviewCheck.require(abs(size.width - 340) <= 1 && size.height > 80 && size.height < 500,
                            "Timing popover has invalid intrinsic size in \(language): \(size)")
            }

        }
        print("PASS Timing popover intrinsic size in RU/EN")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let popover = TrackingPopover()
        let controller = MenuBarController(store: store, statusItem: item, popover: popover, openRoute: { _ in })
        defer { controller.tearDown() }
        try await ReviewCheck.settle()
        let initialImage = item.button!.image
        let initialRectChanges = popover.positioningChanges
        popover.presented = true
        store.setModelIncluded(false, model: "gpt-6-astra")
        store.compactMenuBar.toggle()
        store.interfaceLanguage = .english
        try await ReviewCheck.settle()
        try ReviewCheck.require(item.button!.image === initialImage, "An open popover's status item resized during a data/preference update")
        try ReviewCheck.require(popover.positioningChanges == initialRectChanges, "Refresh forced a new popover anchor")
        popover.presented = false
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: popover))
        try ReviewCheck.require(item.button!.image !== initialImage, "Closing the popover failed to publish the latest badge")
        try ReviewCheck.require(item.button!.toolTip == MenuBarBadge.accessibilityLabel(store.todaySnapshot?.totals, day: store.todaySnapshot?.day), "Closed badge shows stale totals")
        print("PASS Popover updates preserve anchor geometry and publish the latest badge on close")
    }
}
