import XCTest
#if SWIFT_PACKAGE
@testable import LLMUsageCore
#else
@testable import LLMUsage
#endif

final class RefreshScheduleTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_683_200)
    private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }
    private func startingSchedule() -> RefreshSchedule {
        var schedule = RefreshSchedule()
        schedule.reset(day: UsageDay(date: origin), at: origin)
        schedule.succeeded(cost: 1, reason: .startup, at: origin)
        return schedule
    }

    func testFullCycleUsesAdditionalThreeMinutesInMedium() {
        var schedule = startingSchedule()
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, at(180))
        schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
        for second in stride(from: 185, through: 235, by: 5) {
            schedule.succeeded(cost: 2, reason: .automatic, at: at(Double(second)))
            XCTAssertEqual(schedule.mode, .fast)
        }
        schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
        XCTAssertEqual(schedule.mode, .medium)
        XCTAssertEqual(schedule.nextRefresh, at(300))
        for second in [300.0, 360] {
            schedule.succeeded(cost: 2, reason: .automatic, at: at(second))
            XCTAssertEqual(schedule.mode, .medium)
        }
        schedule.succeeded(cost: 2, reason: .automatic, at: at(420))
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, at(600))
    }

    func testManualRefreshSkipsOneSlotAndDoesNotConsumeAutomaticCostChange() {
        var schedule = startingSchedule()
        schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
        schedule.manualRefreshStarted()
        schedule.succeeded(cost: 3, reason: .manual, at: at(183))
        schedule.manualRefreshStarted()
        XCTAssertFalse(schedule.consumeSkippedRefresh(at: at(184)))
        XCTAssertTrue(schedule.consumeSkippedRefresh(at: at(185)))
        XCTAssertEqual(schedule.nextRefresh, at(190))
        XCTAssertFalse(schedule.consumeSkippedRefresh(at: at(190)))
        schedule.succeeded(cost: 3, reason: .automatic, at: at(190))
        schedule.succeeded(cost: 3, reason: .automatic, at: at(245))
        XCTAssertEqual(schedule.mode, .fast)
        schedule.succeeded(cost: 3, reason: .automatic, at: at(250))
        XCTAssertEqual(schedule.mode, .medium)
    }

    func testManualRefreshLeavesSlowAndMediumDeadlinesAlone() {
        var schedule = startingSchedule()
        schedule.manualRefreshStarted()
        schedule.succeeded(cost: 2, reason: .manual, at: at(170))
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, at(180))
        schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
        schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
        schedule.manualRefreshStarted()
        schedule.succeeded(cost: 3, reason: .manual, at: at(260))
        XCTAssertEqual(schedule.mode, .medium)
        XCTAssertEqual(schedule.nextRefresh, at(300))
        schedule.succeeded(cost: 3, reason: .automatic, at: at(300))
        XCTAssertEqual(schedule.mode, .fast)
    }

    func testFailureRestartsEvidenceOfInactivityAndLongQueriesDoNotQueue() {
        var schedule = startingSchedule()
        schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
        schedule.failed(reason: .automatic, at: at(237))
        XCTAssertEqual(schedule.mode, .fast)
        XCTAssertEqual(schedule.nextRefresh, at(240))
        schedule.succeeded(cost: 2, reason: .automatic, at: at(252))
        XCTAssertEqual(schedule.mode, .fast)
        XCTAssertEqual(schedule.nextRefresh, at(255))
        schedule.succeeded(cost: 2, reason: .automatic, at: at(310))
        XCTAssertEqual(schedule.mode, .fast)
        schedule.succeeded(cost: 2, reason: .automatic, at: at(315))
        XCTAssertEqual(schedule.mode, .medium)
    }

    func testDayResetSeedsSlowBaselineAndIgnoresRoundingNoise() {
        var schedule = startingSchedule()
        schedule.succeeded(cost: 1 + 1e-12, reason: .automatic, at: at(180))
        XCTAssertEqual(schedule.mode, .slow)
        schedule.succeeded(cost: 1.0001, reason: .automatic, at: at(360))
        XCTAssertEqual(schedule.mode, .fast)
        let nextDay = UsageDay(date: origin).adding(days: 1)
        schedule.prepare(day: nextDay, at: nextDay.date)
        schedule.succeeded(cost: 0, reason: .automatic, at: nextDay.date)
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, nextDay.date.addingTimeInterval(180))
    }
}
