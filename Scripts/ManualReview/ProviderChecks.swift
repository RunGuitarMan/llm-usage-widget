#if MANUAL_REVIEW
import AppKit
import SwiftUI

/// Observe the logo group in the actual production hierarchy. SwiftUI does not
/// publish an in-process accessibility tree until an external AX client attaches.
struct ReviewProviderProbe: NSViewRepresentable {
    var models: [String]
    var providers: [ModelProvider]
    var label: String

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.models = models
        view.providers = providers
        view.label = label
    }
    final class ProbeView: NSView {
        var models: [String] = []
        var providers: [ModelProvider] = []
        var label = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor enum ProviderChecks {
    static func run(_ review: ManualReviewController) async throws {
        try checkArtwork()
        guard let window = review.dashboard else { return }
        let store = review.store
        for language in [InterfaceLanguage.russian, .english] {
            for appearance in [ReviewAppearance.light, .dark] {
                review.language = language
                review.appearance = appearance
                review.size = .compact
                review.changePresentation()
                try await ReviewCheck.select("provider-models", in: review)
                try await ReviewCheck.resize(window, width: 860)
                let mixed: [ModelProvider] = [.anthropic, .tbank, .custom]
                for (model, expected) in [("openrouter/z-ai/glm-5", [ModelProvider.zai]),
                                          ("tgpt/super-mega-llm-999b", [.tbank]),
                                          ("claude-sonnet-4.6", [.anthropic]),
                                          ("unknown-model", mixed), ("custom-model", [.custom])] {
                    try await ReviewCheck.wait("Wrong production Models logos for \(model)") {
                        probes(in: window).contains { $0.models.contains(model) && $0.providers == expected }
                    }
                }
                for probe in probes(in: window).filter({ $0.providers == mixed }) {
                    try ReviewCheck.require(probe.bounds.width > 60 && probe.bounds.width < 90 && probe.bounds.height == 30,
                                            "Three model brands no longer form a compact, unclipped stack")
                }

                try await ReviewCheck.select("provider-sessions", in: review)
                store.sessionList.query = "tgpt/super-mega-llm-999b"
                try await ReviewCheck.wait("Session row lost T-Bank attribution") {
                    probes(in: window).contains { $0.models == ["tgpt/super-mega-llm-999b"] && $0.providers == [.tbank] }
                }

                try await ReviewCheck.select("provider-inspector", in: review)
                for (id, expected) in [("tgpt", [ModelProvider.tbank]), ("glm", [.zai]), ("mixed", mixed),
                                       ("unknown", [.custom]), ("empty", [.custom]), ("breakdown", [.zai, .tbank])] {
                    store.selectedSessionID = "provider-" + id
                    try await ReviewCheck.resize(window, width: 1160)
                    try await ReviewCheck.wait("Inspector lost production model logos for \(id)") {
                        guard let probe = probes(in: window).max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else { return false }
                        return probe.convert(probe.bounds, to: nil).minX > window.frame.width - 450
                            && probe.providers == expected && probe.label == expected.map(\.title).joined(separator: ", ")
                    }
                }
                print("PASS Model logos: GLM in Claude Code, tgpt priority, mixed/unknown/empty/breakdown models in production UI in \(language.rawValue)/\(appearance.rawValue)")
            }
        }
        try await ReviewCheck.select("overview", in: review)
    }

    private static func probes(in window: NSWindow) -> [ReviewProviderProbe.ProbeView] {
        guard let host = window.contentView else { return [] }
        return ReviewCheck.views(ReviewProviderProbe.ProbeView.self, in: host).filter {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
        }
    }

    private static func checkArtwork() throws {
        for provider in ModelProvider.brandedCases {
            guard let image = ProviderLogo.images[provider] else {
                try ReviewCheck.require(false, "Missing provider artwork: \(provider)"); continue
            }
            try ReviewCheck.require(image.isValid && image.isTemplate, "Invalid provider template: \(provider)")
            var bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
            guard let cgImage = image.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else {
                try ReviewCheck.require(false, "Cannot render provider SVG: \(provider)"); continue
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            var filled = 0, transparent = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if alpha > 0.5 { filled += 1 }
                    if alpha < 0.1 { transparent += 1 }
                }
            }
            try ReviewCheck.require(filled > 10 && transparent > 10, "Blank/opaque provider artwork: \(provider)")
            if provider == .tbank {
                // The official T is a cutout, not an opaque path that disappears in template mode.
                let alpha = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 1
                try ReviewCheck.require(alpha < 0.1, "T-Bank shield lost its T cutout")
            }
        }
        print("PASS Every bundled provider SVG renders visible template artwork, including the T-Bank shield cutout")
    }

}
#endif
