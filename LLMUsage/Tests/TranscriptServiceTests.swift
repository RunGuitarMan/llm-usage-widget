import XCTest

final class TranscriptServiceTests: XCTestCase {
    @MainActor func testServiceScenarios() async {
        await TranscriptServiceScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
