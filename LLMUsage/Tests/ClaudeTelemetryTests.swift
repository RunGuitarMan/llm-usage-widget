import XCTest
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#else
@testable import LLMUsage
#endif

final class ClaudeTelemetryTests: XCTestCase {
    func testTelemetryScenarios() async {
        await ClaudeTelemetryScenarios.run { name, action in
            do { try await action() } catch { XCTFail("\(name): \(error)") }
        }
    }
}
