// swift-tools-version: 5.10
import PackageDescription

// A dependency-free test harness that also runs with Command Line Tools.
// The shipping macOS 26 app and WidgetKit extension are in LLMUsage.xcodeproj.
let package = Package(
    name: "LLMUsageCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LLMUsageCore", targets: ["LLMUsageCore"])],
    targets: [
        .target(name: "LLMUsageCore", path: "LLMUsage", exclude: [
            "Dashboard", "Sessions", "Models", "Settings", "Widget", "Resources", "Tests",
            "App/AppUpdateCoordinator.swift", "App/AppIconAppearance.swift", "App/AppMenuLocalization.swift", "App/DashboardWindowCoordinator.swift", "App/LLMUsageApp.swift", "App/MenuBarBadge.swift", "App/MenuBarUsageView.swift", "App/MenuBarController.swift", "Shared/UsageStyle.swift", "Shared/UsageHistoryViews.swift", "Shared/BrandGeometry.swift", "Shared/UsageHealthViews.swift"
        ], sources: ["Data", "Services", "Shared/UsageModels.swift", "Shared/Localization.swift", "Shared/UsageFormatting.swift",
                     "Shared/UsageRoute.swift", "Shared/UsageHealth.swift", "Shared/UsageHistory.swift", "Shared/SnapshotStorage.swift", "Shared/WidgetPresentation.swift", "Shared/SampleData.swift",
                     "App/RefreshSchedule.swift", "App/UsageStore.swift"]),
        .testTarget(name: "LLMUsageTests", dependencies: ["LLMUsageCore"],
                    path: "LLMUsage/Tests", resources: [.copy("Fixtures")])
    ]
)
