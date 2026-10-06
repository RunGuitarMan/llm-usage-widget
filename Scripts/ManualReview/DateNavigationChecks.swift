import AppKit

@MainActor enum DateNavigationChecks {
    static func run(_ review: ManualReviewController) async throws {
        let window = review.dashboard!
        let store = review.store
        func navigation() -> NSSegmentedControl? {
            window.toolbar?.items.compactMap(\.view)
                .flatMap { ReviewCheck.views(NSSegmentedControl.self, in: $0) }
                .first { $0.identifier?.rawValue == "day-navigation" }
        }
        func press(_ segment: Int) throws {
            guard let control = navigation(), control.window === window else {
                try ReviewCheck.require(false, "Missing native day-navigation action"); return
            }
            // Exercise the real cell's mouse tracking; accessibility proxies do not
            // dispatch presses reliably when invoked from inside their own process.
            let widths = (0..<3).map { control.width(forSegment: $0) }
            let inset = (control.bounds.width - widths.reduce(0, +)) / 2
            let x = inset + widths.prefix(segment).reduce(0, +) + widths[segment] / 2
            let location = control.convert(NSPoint(x: x, y: control.bounds.midY), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                          timestamp: timestamp, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                        timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: true)
            control.mouseDown(with: down)
        }
        for language in [InterfaceLanguage.russian, .english] {
            for appearance in [ReviewAppearance.light, .dark] {
                review.language = language
                review.appearance = appearance
                review.changePresentation()
                try await ReviewCheck.select("calendar", in: review)
                try await ReviewCheck.resize(window, width: 860)
                guard let control = navigation() else {
                    try ReviewCheck.require(false, "Custom date lost its native navigation capsule"); return
                }
                let originalFrame = control.convert(control.bounds, to: nil)
                try ReviewCheck.require(control.segmentCount == 3 && control.trackingMode == .momentary,
                                        "Date capsule does not have three momentary actions")
                try ReviewCheck.require(control.toolTip(forSegment: 0) == L10n.text("Предыдущий день")
                    && control.toolTip(forSegment: 2) == L10n.text("Следующий день"), "Day-navigation labels did not localize")
                try ReviewCheck.require(originalFrame.width >= 224 && originalFrame.minX > 200
                    && originalFrame.maxX < window.frame.width - 130, "Date capsule clips or overlaps trailing actions")
                let first = store.selectedDay
                let cost = store.snapshot?.totals.cost
                try press(0)
                try await ReviewCheck.wait("Previous-day button did not update the report") {
                    store.selectedDay == first.adding(days: -1) && store.snapshot?.day == store.selectedDay
                }
                try ReviewCheck.require(store.snapshot?.totals.cost != cost && store.dailyBudget == 100,
                                        "Day navigation did not update budget usage")
                for _ in 0..<5 { try press(0) }
                try await ReviewCheck.wait("Repeated native day actions lost clicks or loaded an obsolete day") {
                    store.selectedDay == first.adding(days: -6) && store.snapshot?.day == store.selectedDay
                }
                try await ReviewCheck.settle()
                try ReviewCheck.require(control.convert(control.bounds, to: nil) == originalFrame,
                                        "Date capsule moved while stepping across a month boundary")
                let labelWidth = (control.label(forSegment: 1)! as NSString).size(withAttributes: [.font: control.font!]).width
                try ReviewCheck.require(labelWidth + 36 < control.width(forSegment: 1), "Localized date does not fit its segment")

                let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                try press(1)
                var popover: NSWindow?
                try await ReviewCheck.wait("Date segment did not open the production calendar") {
                    popover = NSApp.windows.first { $0.isVisible && !visible.contains(ObjectIdentifier($0)) }
                    return popover != nil
                }
                let beforePopoverStep = store.selectedDay
                try press(2)
                try await ReviewCheck.wait("Day action did not close the calendar and change the date") {
                    popover?.isVisible != true && store.selectedDay == beforePopoverStep.adding(days: 1)
                        && store.snapshot?.day == store.selectedDay
                }
                let today = UsageDay(date: Date(), timezone: store.timezone)
                await store.selectCustomDate(today.date)
                try await ReviewCheck.wait("Today did not disable the forward segment") {
                    navigation()?.isEnabled(forSegment: 2) == false
                }
                try ReviewCheck.require(store.period == .custom && store.selectedDay == today,
                                        "Today's forward action changed the period/date")
                try press(0)
                try await ReviewCheck.wait("Leaving today did not restore the forward action") {
                    store.selectedDay == today.adding(days: -1) && navigation()?.isEnabled(forSegment: 2) == true
                }
                try ReviewCheck.toolbar(review)
                print("PASS Native day navigation: rapid clicks, budget, calendar dismissal, fixed geometry and today in \(language.rawValue)/\(appearance.rawValue)")
            }
        }
        try await ReviewCheck.select("overview", in: review)
        try ReviewCheck.require(navigation() == nil, "Today preset retained custom-date arrows")
    }
}
