import Foundation
import SwiftUI
import WidgetKit
import Darwin

private actor WidgetFixtureService: CCUsageServing {
    var cost = 12.34
    var date: Date
    init(date: Date) { self.date = date }
    func update(cost: Double, date: Date) { self.cost = cost; self.date = date }
    func fetch(day: UsageDay, customPath: String, mode: UsageUpdateMode) async throws -> UsageSnapshot {
        .init(generatedAt: date, day: day, sessions: [
            .init(id: "widget-fixture", models: ["fixture"], usage: .init(input: 1234, output: 234, cost: cost))
        ])
    }
    func diagnose(customPath: String, forceDetect: Bool) async throws -> CLIDiagnostics {
        .init(path: "/review/fixture", version: "fixture")
    }
}

@MainActor enum WidgetChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "WidgetChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
        let repository = SnapshotRepository(directory: directory)
        let service = WidgetFixtureService(date: date)
        var reloads = 0
        let store = UsageStore(service: service, repository: repository, defaults: defaults,
                               now: { date }, widgetReloadDelay: 0, reloadWidget: { reloads += 1 })
        let provider = UsageTimelineProvider(directory: directory, now: { date })

        let empty = provider.readEntry()
        try ReviewCheck.require(empty.snapshot == nil && !empty.storageUnavailable, "Clean install was mistaken for a storage error")
        let preview = UsageTimelineProvider(directory: nil, now: { date }).previewEntry()
        try ReviewCheck.require(preview.snapshot != nil && preview.history != nil && !preview.storageUnavailable,
                                "Gallery preview depends on readable user storage")

        await store.refresh()
        await store.waitForHistoryBackfill()
        await store.waitForWidgetPublication()
        let first = provider.readEntry()
        try ReviewCheck.require(first.snapshot?.totals.cost == 12.34 && first.snapshot == store.todaySnapshot.map(WidgetSnapshot.init),
                                "Widget provider does not read the snapshot published by the app")
        try ReviewCheck.require(reloads > 0 && first.history?.days.count == 7, "Publication did not reload widgets or persist history")
        let timeline = provider.makeTimeline()
        try ReviewCheck.require(timeline.entries.first?.snapshot == first.snapshot,
                                "Timeline uses different data than snapshot requests")
        try ReviewCheck.require(timeline.entries.contains { $0.date == first.snapshot?.day.end }, "No midnight transition")
        try ReviewCheck.require(timeline.entries.contains { $0.snapshot?.isStale(now: $0.date) == true }, "No stale transition while app is closed")

        date = date.addingTimeInterval(60)
        await service.update(cost: 56.78, date: date)
        await store.refresh()
        await store.waitForHistoryBackfill()
        await store.waitForWidgetPublication()
        let second = provider.readEntry()
        try ReviewCheck.require(second.snapshot?.totals.cost == 56.78 && second.snapshot == store.todaySnapshot.map(WidgetSnapshot.init),
                                "Provider retained A after the app atomically published B")
        try ReviewCheck.require(second.snapshot?.generatedAt == date, "Widget generation timestamp did not advance")
        try Data("broken".utf8).write(to: directory.appendingPathComponent("daily-history-v1.json"), options: .atomic)
        try ReviewCheck.require(provider.readEntry().snapshot?.totals.cost == 56.78,
                                "Optional history failure hid a valid current snapshot")
        try Data("broken".utf8).write(to: directory.appendingPathComponent(SnapshotSlot.today.rawValue), options: .atomic)
        let published = provider.readEntry()
        try ReviewCheck.require(published.snapshot == second.snapshot && published.history == second.history
                                && !published.storageUnavailable,
                                "Damaged legacy files overrode the valid atomic presentation")
        try Data("broken".utf8).write(to: directory.appendingPathComponent(WidgetPresentation.filename), options: .atomic)
        let corrupt = provider.readEntry()
        try ReviewCheck.require(corrupt.snapshot == nil && corrupt.storageUnavailable,
                                "Corrupt presentation silently appeared as loading")
        await store.refresh()
        await store.waitForHistoryBackfill()
        await store.waitForWidgetPublication()
        try ReviewCheck.require(provider.readEntry().snapshot?.totals.cost == 56.78 && !provider.readEntry().storageUnavailable,
                                "Widget did not recover after storage was repaired")
        date = first.snapshot!.day.end
        try ReviewCheck.require(provider.readEntry().snapshot?.day.isToday(now: date) == false,
                                "Yesterday's saved total was relabelled as today's")
        print("PASS Widget provider: clean install, gallery without storage, app publication A → B, timeline, corrupt file recovery and midnight")

        let current = WidgetExtensionLifecycle.Identity(identifier: "local.fixture.Widget", digest: Data([1]))
        let path = "/fixture/LLM Usage.app/Contents/PlugIns/LLMUsageWidget.appex/Contents/MacOS/LLMUsageWidget"
        var process = WidgetExtensionLifecycle.ProcessIdentity(pid: 12345, path: path, code: current)
        try ReviewCheck.require(!WidgetExtensionLifecycle.shouldRetire(process, current: current, executable: path), "Current extension is terminated")
        process.code.digest = Data([2])
        try ReviewCheck.require(WidgetExtensionLifecycle.shouldRetire(process, current: current, executable: path), "Mapped old binary survives bundle replacement")
        process.code = current; process.path = "/old-build" + path
        try ReviewCheck.require(WidgetExtensionLifecycle.shouldRetire(process, current: current, executable: path), "Old build-directory extension survives relocation")
        process.code.identifier = "local.other.Widget"
        try ReviewCheck.require(!WidgetExtensionLifecycle.shouldRetire(process, current: current, executable: path), "Another app's widget was selected for termination")
        process.code = current; process.pid = 0
        try ReviewCheck.require(!WidgetExtensionLifecycle.shouldRetire(process, current: current, executable: path), "Invalid PID was selected for termination")
        print("PASS Widget lifecycle: stale executable/path detection, current process and other bundle isolation")
        try await cachedHostRecovery()
        try await WidgetProcessFixture.run()
        try renderContentModes()
    }

    /// Content exports cover our rendering-mode branches, not WidgetKit's
    /// compositor or native window behavior. Uses views in the common app.
    private static func renderContentModes() throws {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--review-report-dir"), args.indices.contains(index + 1) else {
            try ReviewCheck.require(false, "Rendering exports require the review report directory"); return
        }
        let directory = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("widget-rendering")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
        let modes: [(String, WidgetRenderingMode)] = [("fullColor", .fullColor), ("accented", .accented), ("vibrant", .vibrant)]
        for (name, mode) in modes {
            for variant in UsageWidgetVariant.allCases {
                for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
                    let view = WidgetPreviewCard(family: family, variant: variant, history: SampleData.history(now: date),
                        snapshot: SampleData.multiSourceSnapshot(now: date), date: date)
                        .environment(\.widgetRenderingMode, mode)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "WidgetRendering", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot render \(variant.rawValue)/\(family)/\(name)"])
                    }
                    try ReviewCheck.require(image.size.width > 100 && image.size.height > 100, "Empty widget content")
                    try png.write(to: directory.appendingPathComponent("\(variant.rawValue)-\(family.rawValue)-\(name).png"))
                }
            }
        }
        print("PASS Widget content: 3 rendering modes × 3 variants × 3 sizes (27 exports; system compositor checked separately)")
    }

    private static func cachedHostRecovery() async throws {
        typealias Lifecycle = WidgetExtensionLifecycle
        let host = Lifecycle.HostIdentity(pid: 12345, startSeconds: 100, startMicroseconds: 42)
        let identifier = "local.fixture.Widget"
        let currentBundle = "/Applications/LLM Usage.app/Contents/PlugIns/LLMUsageWidget.appex"
        let oldBundle = "/deleted build/LLM Usage.app/Contents/PlugIns/LLMUsageWidget.appex"
        let suffix = "/Contents/MacOS/LLMUsageWidget"
        // Captured field structure of the failing launchd job, including a nested
        // misleading field that must never override the top-level executable.
        let output = """
        pid/12345/local.fixture.Widget = {
        \ttype = Extension
        \tpath = \(oldBundle)
        \tbundle id = local.fixture.Widget
        \textension point = com.apple.widgetkit-extension
        \tprogram = \(oldBundle + suffix)
        \tenvironment = {
        \t\tprogram = /unrelated/program
        \t}
        }
        """
        let stale = Lifecycle.cachedJob(output, hostPID: host.pid, identifier: identifier)
        try ReviewCheck.require(stale?.executable == oldBundle + suffix, "Deleted-build launch job was not recognized")
        for malformed in ["", "Could not find service", output.replacingOccurrences(of: "pid/12345/", with: "pid/999/"),
                          output.replacingOccurrences(of: "bundle id = local.fixture.Widget", with: "bundle id = other.Widget"),
                          output.replacingOccurrences(of: "type = Extension", with: "type = LaunchAgent"),
                          output.replacingOccurrences(of: "com.apple.widgetkit-extension", with: "other.extension"),
                          output.replacingOccurrences(of: "\tprogram = \(oldBundle + suffix)", with: "\tprogram = /bin/sleep"),
                          output + "\n\tprogram = \(oldBundle + suffix)", String(output.dropLast())] {
            try ReviewCheck.require(Lifecycle.cachedJob(malformed, hostPID: host.pid, identifier: identifier) == nil,
                                    "Ambiguous/foreign launch job permits host recovery")
        }
        let current = Lifecycle.CachedJob(identifier: identifier, executable: currentBundle + suffix)
        let alias = Lifecycle.CachedJob(identifier: identifier, executable: "/Applications/../Applications" + String((currentBundle + suffix).dropFirst("/Applications".count)))
        let foreign = Lifecycle.CachedJob(identifier: "other.Widget", executable: oldBundle + suffix)
        let recycled = Lifecycle.HostIdentity(pid: host.pid, startSeconds: 101, startMicroseconds: 0)
        func check(_ name: String, jobs: [Lifecycle.CachedJob?], hosts: [Lifecycle.HostIdentity?], expected: Bool) async throws {
            var jobIndex = 0, hostIndex = 0
            var signals: [pid_t] = []
            let result = await Lifecycle.recoverHost(host, identifier: identifier, executable: currentBundle + suffix,
                identify: { _ in
                    defer { hostIndex += 1 }
                    return hosts[min(hostIndex, hosts.count - 1)]
                }, inspect: { _, _ in
                    defer { jobIndex += 1 }
                    return jobs[min(jobIndex, jobs.count - 1)]
                }, terminate: { pid in signals.append(pid); return true })
            try ReviewCheck.require(result == expected && signals == (expected ? [host.pid] : []), "Unsafe host recovery: \(name)")
        }
        try await check("deleted build with no running extension", jobs: [stale, stale], hosts: [host], expected: true)
        try await check("current path", jobs: [current], hosts: [host], expected: false)
        try await check("canonical path alias", jobs: [alias], hosts: [host], expected: false)
        try await check("unavailable diagnostics", jobs: [nil], hosts: [host], expected: false)
        try await check("another widget", jobs: [foreign], hosts: [host], expected: false)
        try await check("job corrected during lookup", jobs: [stale, current], hosts: [host], expected: false)
        try await check("host disappeared", jobs: [stale], hosts: [host, nil], expected: false)
        try await check("PID recycled before lookup", jobs: [stale], hosts: [recycled], expected: false)
        try await check("PID recycled before signal", jobs: [stale], hosts: [host, host, recycled], expected: false)
        try ReviewCheck.require(Lifecycle.hostIdentity(getpid()) == nil && Lifecycle.hostIdentity(0) == nil,
                                "A non-host process was accepted for host recovery")
        let now = Date(timeIntervalSince1970: 1_000)
        try ReviewCheck.require(Lifecycle.recoveryAllowed(lastRecovery: nil, now: now)
            && !Lifecycle.recoveryAllowed(lastRecovery: now.addingTimeInterval(-299), now: now)
            && Lifecycle.recoveryAllowed(lastRecovery: now.addingTimeInterval(-300), now: now)
            && Lifecycle.recoveryAllowed(lastRecovery: now.addingTimeInterval(1), now: now), "Host recovery cooldown is incorrect")
        print("PASS Widget host recovery: deleted launch path, healthy/foreign jobs, fail-closed parsing, PID/job races and restart cooldown")
    }
}
