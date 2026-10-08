import XCTest

final class WidgetStabilityTests: XCTestCase {
    @MainActor func testWidgetPublicationAndProjection() async {
        await WidgetStabilityScenarios.run { name, action in
            do { try await action() } catch { XCTFail("\(name): \(error)") }
        }
    }
}
