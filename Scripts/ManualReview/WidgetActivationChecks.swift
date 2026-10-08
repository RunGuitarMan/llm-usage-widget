#if MANUAL_REVIEW
import AppKit

/// Exercise the production delegate through actual URL Apple events while its
/// real dashboard is hidden/minimized. Never send a link to an installed app.
@MainActor enum WidgetActivationChecks {
    static func run(_ review: ManualReviewController) async throws {
        guard let window = review.dashboard, let delegate = review.appDelegate else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try await ReviewCheck.select("overview", in: review)
        window.performClose(nil)
        try await ReviewCheck.wait("Dashboard did not hide before widget activation") { !window.isVisible }
        try send(UsageRoute.settings.url)
        try await ReviewCheck.wait("Widget URL did not reopen the hidden production dashboard") {
            window.isVisible && window.alphaValue == 1 && review.store.tab == .settings
        }
        try ReviewCheck.require(review.dashboard === window, "Widget URL created a second dashboard")
        print("PASS Widget URL Apple event reopens the hidden dashboard and navigates to Settings")

        window.miniaturize(nil)
        try await ReviewCheck.wait("Dashboard did not minimize") { window.isMiniaturized }
        try send(UsageRoute.sessions.url)
        try await ReviewCheck.wait("Widget URL did not restore the minimized dashboard") {
            !window.isMiniaturized && window.isVisible && review.store.tab == .overview
                && review.store.sessionList.isExpanded
        }
        print("PASS Widget URL restores the minimized dashboard and opens Sessions")

        let day = review.store.todaySnapshot!.day.adding(days: -1)
        let route = UsageRoute.problem(.init(kind: .cost, day: day))
        window.orderOut(nil)
        try send(route.url)
        try await ReviewCheck.wait("Widget problem URL lost its date or did not present the real sheet") {
            window.isVisible && window.attachedSheet != nil
                && review.store.presentedProblem == .init(kind: .cost, day: day)
        }
        review.store.presentedProblem = nil
        try await ReviewCheck.wait("Widget problem sheet did not close") { window.attachedSheet == nil }
        print("PASS Widget warning URL preserves the historical day in the production details sheet")

        window.orderOut(nil)
        try send(URL(string: "llmusage://problem/invalid")!)
        try await ReviewCheck.settle()
        try ReviewCheck.require(!window.isVisible, "Malformed widget URL opened the dashboard")
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        try await ReviewCheck.wait("Plain reopen no longer reveals the dashboard") { window.isVisible }

        let current = WidgetExtensionLifecycle.Identity(identifier: "fixture.Widget", digest: Data([2]))
        let executable = "/fixture/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget"
        let pid: pid_t = getpid() + 1
        let old = WidgetExtensionLifecycle.ProcessIdentity(pid: pid, path: executable,
            code: .init(identifier: current.identifier, digest: Data([1])))
        let new = WidgetExtensionLifecycle.ProcessIdentity(pid: pid, path: executable, code: current)
        var replacedOnDisk = new
        replacedOnDisk.staticCodeChanged = true
        let foreign = WidgetExtensionLifecycle.ProcessIdentity(pid: pid, path: executable,
            code: .init(identifier: "another.Widget", digest: Data([1])))
        try ReviewCheck.require(WidgetExtensionLifecycle.shouldRetire(old, current: current, executable: executable)
            && WidgetExtensionLifecycle.shouldRetire(replacedOnDisk, current: current, executable: executable)
            && !WidgetExtensionLifecycle.shouldRetire(new, current: current, executable: executable)
            && !WidgetExtensionLifecycle.shouldRetire(foreign, current: current, executable: executable),
            "Widget recovery must retire only the obsolete extension belonging to this app")
        print("PASS Widget recovery distinguishes stale/current/foreign extension signatures")
        let ownExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget").path
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let installation = cache.appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent("org.sparkle-project.Sparkle/Installation")
        let oldImage = installation.appendingPathComponent("old/download")
            .appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
            .appendingPathComponent("Contents/PlugIns/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget").path
        try ReviewCheck.require(WidgetExtensionLifecycle.belongsToUpdate(oldImage, executable: ownExecutable)
            && !WidgetExtensionLifecycle.belongsToUpdate(oldImage.replacingOccurrences(of: Bundle.main.bundleIdentifier!, with: "another.host"), executable: ownExecutable)
            && !WidgetExtensionLifecycle.belongsToUpdate(oldImage.replacingOccurrences(of: "/old/download/", with: "/../foreign/"), executable: ownExecutable),
            "Deleted-image recovery escaped the current app's Sparkle cache")
        print("PASS Deleted-image recovery is limited to the current app's update directory")

        var failures: [String] = []
        await UsageHealthScenarios.run { name, action in
            do { try await action(); print("PASS \(name)") }
            catch { failures.append(name + ": " + String(describing: error)) }
        }
        try ReviewCheck.require(failures.isEmpty, failures.joined(separator: "\n"))
        try await ReviewCheck.select("overview", in: review)
    }

    private static func send(_ url: URL) throws {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL), targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        _ = try event.sendEvent(options: .noReply, timeout: 2)
    }
}
#endif
