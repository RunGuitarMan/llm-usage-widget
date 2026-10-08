import XCTest

final class UsageHealthTests: XCTestCase {
    @MainActor func testSharedProblemLifecycle() async {
        await UsageHealthScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
