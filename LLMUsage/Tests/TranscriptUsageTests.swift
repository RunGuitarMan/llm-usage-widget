import XCTest

final class TranscriptUsageTests: XCTestCase {
    @MainActor func testUsageAttribution() async {
        await TranscriptUsageScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
