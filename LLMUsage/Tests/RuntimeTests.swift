import XCTest

final class RuntimeTests: XCTestCase {
    @MainActor func testRuntimeAndUpdates() async {
        await RuntimeScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
