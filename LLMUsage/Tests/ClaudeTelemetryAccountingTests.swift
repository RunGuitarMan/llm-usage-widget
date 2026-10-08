import XCTest
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#else
@testable import LLMUsage
#endif

final class ClaudeTelemetryAccountingTests: XCTestCase {
    func testScenarios() async {
        await ClaudeTelemetryAccountingScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
