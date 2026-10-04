import XCTest

final class TranscriptTimingTests: XCTestCase {
    @MainActor func testTimingScenarios() async {
        await TranscriptTimingScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
