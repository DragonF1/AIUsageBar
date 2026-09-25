import XCTest
@testable import AIUsageBar

/// Covers the pure scheduling decisions behind the activity-triggered refresh: the quiet period
/// after the last filesystem event, the floor between any two fetches, and that a burst of
/// events coalesces into a single fire. `ActivityWatcher` itself (the FSEvents plumbing) is not
/// exercised here since it needs a real filesystem and a run loop; this is the part that matters.
@MainActor
final class ActivityRefreshSchedulerTests: XCTestCase {
    /// A mutable clock the tests advance by hand, so the scheduler's decisions are deterministic.
    final class Clock {
        var now: Date
        init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func testCheckAndFireIsANoOpWithNoPendingEvent() {
        let clock = Clock()
        var fired = 0
        let scheduler = ActivityRefreshScheduler(now: { clock.now }, onFire: { fired += 1 })
        XCTAssertFalse(scheduler.checkAndFire())
        XCTAssertEqual(fired, 0)
    }

    func testFiresAfterTheQuietPeriod() {
        let clock = Clock()
        var fired = 0
        let scheduler = ActivityRefreshScheduler(now: { clock.now }, onFire: { fired += 1 })
        scheduler.activityDetected()
        clock.advance(1.9)
        XCTAssertFalse(scheduler.checkAndFire(), "still inside the 2s quiet period")
        clock.advance(0.2)
        XCTAssertTrue(scheduler.checkAndFire(), "2.1s after the event, the quiet period has passed")
        XCTAssertEqual(fired, 1)
    }

    func testRepeatedEventsCoalesceIntoOneFire() {
        let clock = Clock()
        var fired = 0
        let scheduler = ActivityRefreshScheduler(now: { clock.now }, onFire: { fired += 1 })
        scheduler.activityDetected()
        clock.advance(1)
        scheduler.activityDetected() // pushes the pending fire out again
        clock.advance(1)
        scheduler.activityDetected() // and again: only the latest event should matter
        clock.advance(1.9)
        XCTAssertFalse(scheduler.checkAndFire())
        clock.advance(0.2)
        XCTAssertTrue(scheduler.checkAndFire())
        XCTAssertEqual(fired, 1, "three events inside one quiet period should still fire once")
    }

    func testFloorsAtTheMinimumFetchIntervalSinceTheLastFetch() {
        let clock = Clock()
        var fired = 0
        let scheduler = ActivityRefreshScheduler(now: { clock.now }, initialLastFetchAt: clock.now, onFire: { fired += 1 })
        // An event 5s after the seeded fetch would normally fire 2s later (7s total), but the
        // 15s floor since the last fetch pushes it out further.
        clock.advance(5)
        scheduler.activityDetected()
        clock.advance(9) // 14s since the seeded fetch
        XCTAssertFalse(scheduler.checkAndFire())
        clock.advance(1.1) // 15.1s since the seeded fetch
        XCTAssertTrue(scheduler.checkAndFire())
        XCTAssertEqual(fired, 1)
    }

    func testANewBurstAfterAFireRespectsTheFloorAgain() {
        let clock = Clock()
        var fired = 0
        let scheduler = ActivityRefreshScheduler(now: { clock.now }, onFire: { fired += 1 })
        scheduler.activityDetected()
        clock.advance(2)
        XCTAssertTrue(scheduler.checkAndFire())
        XCTAssertEqual(fired, 1)

        // Immediately another event: the 15s floor since that fetch overrides the 2s quiet period.
        scheduler.activityDetected()
        clock.advance(2)
        XCTAssertFalse(scheduler.checkAndFire())
        clock.advance(13.1) // 15.1s since the first fetch
        XCTAssertTrue(scheduler.checkAndFire())
        XCTAssertEqual(fired, 2)
    }

    func testCheckAndFireClearsThePendingFire() {
        let clock = Clock()
        var fired = 0
        let scheduler = ActivityRefreshScheduler(now: { clock.now }, onFire: { fired += 1 })
        scheduler.activityDetected()
        clock.advance(2)
        XCTAssertTrue(scheduler.checkAndFire())
        XCTAssertNil(scheduler.pendingFireAt)
        // Nothing pending: a second poll right away should not fire again.
        XCTAssertFalse(scheduler.checkAndFire())
        XCTAssertEqual(fired, 1)
    }
}
