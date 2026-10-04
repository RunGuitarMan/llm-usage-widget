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

    func testManualRefreshSkipsOneSlotAndStartsQuietWindowAtManualChange() {
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
        schedule.succeeded(cost: 3, reason: .automatic, at: at(240))
        XCTAssertEqual(schedule.mode, .fast)
        schedule.succeeded(cost: 3, reason: .automatic, at: at(245))
        XCTAssertEqual(schedule.mode, .medium)
    }

    func testManualCostChangesAccelerateFromSlowAndMediumWithoutSkippingFirstFastSlot() {
        for medium in [false, true] {
            for cost in [0.5, 3.0] {
                var schedule = startingSchedule()
                if medium {
                    schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
                    schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
                }
                let completion = medium ? 260.0 : 100.0
                schedule.manualRefreshStarted()
                schedule.succeeded(cost: cost, reason: .manual, at: at(completion))
                XCTAssertEqual(schedule.mode, .fast)
                XCTAssertEqual(schedule.nextRefresh, at(completion + 5))
                XCTAssertFalse(schedule.consumeSkippedRefresh(at: at(completion + 5)))
            }
        }
    }

    func testUnchangedManualRefreshPreservesSlowAndMediumDeadlines() {
        for medium in [false, true] {
            var schedule = startingSchedule()
            if medium {
                schedule.succeeded(cost: 2, reason: .automatic, at: at(180))
                schedule.succeeded(cost: 2, reason: .automatic, at: at(240))
            }
            let mode = schedule.mode, deadline = schedule.nextRefresh
            schedule.manualRefreshStarted()
            schedule.succeeded(cost: medium ? 2 : 1, reason: .manual, at: at(medium ? 260 : 100))
            XCTAssertEqual(schedule.mode, mode)
            XCTAssertEqual(schedule.nextRefresh, deadline)
            XCTAssertFalse(schedule.consumeSkippedRefresh(at: deadline!))
        }
    }

    func testManualRefreshUsesSameInactivityTransitionsAsAutomatic() {
        var schedule = startingSchedule()
        schedule.succeeded(cost: 2, reason: .manual, at: at(100))
        schedule.manualRefreshStarted()
        schedule.succeeded(cost: 2, reason: .manual, at: at(160))
        XCTAssertEqual(schedule.mode, .medium)
        XCTAssertEqual(schedule.nextRefresh, at(220))
        schedule.succeeded(cost: 2, reason: .manual, at: at(340))
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, at(520))
    }

    func testFirstManualResultSeedsBaselineWithoutAccelerating() {
        var schedule = RefreshSchedule()
        schedule.reset(day: UsageDay(date: origin), at: origin)
        schedule.succeeded(cost: 10, reason: .manual, at: at(5))
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, at(185))
        schedule.succeeded(cost: 11, reason: .manual, at: at(10))
        XCTAssertEqual(schedule.mode, .fast)
        XCTAssertEqual(schedule.nextRefresh, at(15))
    }

    func testSelectionDoesNotConsumeCostChange() {
        var schedule = startingSchedule()
        schedule.succeeded(cost: 2, reason: .selection, at: at(100))
        XCTAssertEqual(schedule.mode, .slow)
        XCTAssertEqual(schedule.nextRefresh, at(180))
        schedule.succeeded(cost: 2, reason: .manual, at: at(110))
        XCTAssertEqual(schedule.mode, .fast)
        XCTAssertEqual(schedule.nextRefresh, at(115))
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
