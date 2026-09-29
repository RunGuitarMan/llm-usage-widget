import XCTest

final class RegressionTests: XCTestCase {
    @MainActor func testAuditRegressions() async {
        await RegressionScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
