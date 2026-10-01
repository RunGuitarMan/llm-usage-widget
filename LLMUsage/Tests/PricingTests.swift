import XCTest

final class PricingTests: XCTestCase {
    @MainActor func testPricingCache() async {
        await PricingScenarios.run { name, action in
            do { try await action() }
            catch { XCTFail("\(name): \(error)") }
        }
    }
}
