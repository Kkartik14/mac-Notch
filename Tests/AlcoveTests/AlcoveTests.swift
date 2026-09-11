import XCTest
@testable import Alcove

// MARK: - IslandCenter: live activities

final class IslandCenterTests: XCTestCase {

    func testStartsIdle() {
        let c = IslandCenter()
        XCTAssertTrue(c.islands.isEmpty)
        XCTAssertNil(c.expandedId)
    }

    func testShortTimerAutoDismissesAtZero() {
        let c = IslandCenter()
        var t = TimerActivity(seconds: 2, label: "Timer")
        t.endDate = Date().addingTimeInterval(2)
        c.present(.timer(t), autoDismissAfter: nil, expand: true)
        XCTAssertEqual(c.expandedId, "timer")
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        XCTAssertTrue(c.islands.isEmpty, "timer must dismiss itself at zero")
        XCTAssertNil(c.expandedId)
    }

    func testTimerPauseFreezesAndResumeReanchorsToDeviceClock() {
        let c = IslandCenter()
        var t = TimerActivity(seconds: 60, label: "Timer")
        t.endDate = Date().addingTimeInterval(60)
        c.present(.timer(t), autoDismissAfter: nil, expand: true)

        c.pauseResumeTimer()
        guard case .timer(let paused) = c.islands.first(where: { $0.id == "timer" })! else {
            return XCTFail("timer missing")
        }
        XCTAssertTrue(paused.isPaused)
        let frozen = paused.remainingSeconds
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard case .timer(let still) = c.islands.first(where: { $0.id == "timer" })! else {
            return XCTFail("timer missing")
        }
        XCTAssertEqual(still.remainingSeconds, frozen, "paused timer must not tick")

        c.pauseResumeTimer()
        guard case .timer(let resumed) = c.islands.first(where: { $0.id == "timer" })! else {
            return XCTFail("timer missing")
        }
        XCTAssertFalse(resumed.isPaused)
        XCTAssertNotNil(resumed.endDate, "resume must re-anchor endDate to the device clock")
    }

    func testTimerAddMinuteExtends() {
        let c = IslandCenter()
        var t = TimerActivity(seconds: 60, label: "Timer")
        t.endDate = Date().addingTimeInterval(60)
        c.present(.timer(t), autoDismissAfter: nil, expand: true)
        c.pauseResumeTimer() // pause so remaining is deterministic
        guard case .timer(let before) = c.islands.first! else { return XCTFail() }
        c.addMinuteToTimer()
        guard case .timer(let after) = c.islands.first! else { return XCTFail() }
        XCTAssertEqual(after.totalSeconds, before.totalSeconds + 60)
        XCTAssertEqual(after.remainingSeconds, before.remainingSeconds + 60)
    }

    func testTimerCancelClears() {
        let c = IslandCenter()
        var t = TimerActivity(seconds: 60, label: "Timer")
        t.endDate = Date().addingTimeInterval(60)
        c.present(.timer(t), autoDismissAfter: nil, expand: true)
        c.cancelTimer()
        XCTAssertTrue(c.islands.isEmpty)
        XCTAssertNil(c.expandedId)
    }

    func testCollapseKeepsActivityAlive() {
        let c = IslandCenter()
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: nil, expand: true)
        XCTAssertEqual(c.expandedId, "notification")
        c.collapse("notification")
        XCTAssertNil(c.expandedId)
        XCTAssertEqual(c.islands.count, 1, "collapse must keep the activity, unlike dismiss")
    }

    func testCollapseAfterAutoSettlesCardToPill() {
        let c = IslandCenter()
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: nil, expand: true, collapseAfter: 0.5)
        XCTAssertEqual(c.expandedId, "notification")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertNil(c.expandedId, "card must settle back to pill")
        XCTAssertEqual(c.islands.count, 1, "activity must survive the settle")
    }

    func testQuietMonitorUpdatesNeverHijack() {
        let c = IslandCenter()
        c.present(.weather(WeatherActivity(temperatureC: 15, condition: "Clear", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        XCTAssertNil(c.expandedId, "passive updates must not steal the island")
        XCTAssertEqual(c.islands.count, 1)
        // A repeat refresh must not expand either.
        c.present(.weather(WeatherActivity(temperatureC: 16, condition: "Clear", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        XCTAssertNil(c.expandedId)
        XCTAssertEqual(c.islands.count, 1, "same id must update in place, not duplicate")
    }

    func testDismissFallsBackToPreviousActivity() {
        let c = IslandCenter()
        c.present(.weather(WeatherActivity(temperatureC: 15, condition: "C", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: nil, expand: true)
        c.dismiss("notification")
        XCTAssertEqual(c.expandedId, "weather")
    }

    func testDismissAll() {
        let c = IslandCenter()
        c.present(.weather(WeatherActivity(temperatureC: 15, condition: "C", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        c.dismissAll()
        XCTAssertTrue(c.islands.isEmpty)
        XCTAssertNil(c.expandedId)
    }

    func testActivityStackCapped() {
        let c = IslandCenter()
        for i in 0..<6 {
            c.present(.notification(NotificationActivity(appName: "A\(i)", sender: "B", body: "C", icon: "m")),
                      autoDismissAfter: nil, expand: false)
            // Unique ids to force growth.
            c.dismiss("notification")
            c.present(.focus(FocusActivity(mode: "M\(i)")), autoDismissAfter: nil, expand: false)
        }
        XCTAssertLessThanOrEqual(c.islands.count, 4)
    }

    func testAutoDismissRemoves() {
        let c = IslandCenter()
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: 0.5, expand: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(c.islands.isEmpty)
    }

    func testNowPlayingProgressMath() {
        let n = NowPlayingActivity(title: "T", artist: "A", isPlaying: true, elapsed: 60, duration: 240)
        XCTAssertEqual(n.progress, 0.25, accuracy: 0.001)
        let zero = NowPlayingActivity(title: "T", artist: "A", isPlaying: false)
        XCTAssertEqual(zero.progress, 0)
    }

    func testTimerProgressMath() {
        var t = TimerActivity(seconds: 60, label: "T")
        t.remainingSeconds = 15
        XCTAssertEqual(t.progress, 0.75, accuracy: 0.001)
    }
}

// MARK: - Positioning: the anti-slide contract

final class PositioningTests: XCTestCase {
    // Built-in 14" geometry: 1512x982, menu bar 32, notch gap 663..848.
    let notchMin = 663.0, notchMax = 848.0
    let midX = 756.0, menuBar = 32.0, maxY = 982.0

    func origin(w: Double, h: Double) -> CGPoint {
        IslandWindowController.islandOrigin(width: w, height: h,
                                           screenMidX: midX, menuBarHeight: menuBar,
                                           screenMaxY: maxY)
    }

    func testIdlePillSitsInNotch() {
        let o = origin(w: 180, h: 32)
        XCTAssertEqual(o.x, 666.0, accuracy: 0.01)
        XCTAssertEqual(o.y, 950.0, accuracy: 0.01)
    }

    func testExpandedCardCentersOnScreen() {
        let o = origin(w: 320, h: 150)
        XCTAssertEqual(o.x, 596.0, accuracy: 0.01)
        XCTAssertEqual(o.y, 832.0, accuracy: 0.01)
    }

    func testTopEdgePinnedForEveryHeight() {
        for h in [32.0, 60, 100, 150, 200] {
            let o = origin(w: 320, h: h)
            XCTAssertEqual(o.y + h, maxY, accuracy: 0.001, "top edge must never move (h=\(h))")
        }
    }

    func testCenterNeverMovesWhileGrowing() {
        // The core anti-slide guarantee: sweeping width from pill to card,
        // the horizontal center must stay exactly put.
        var lastCenter: Double?
        var w = 180.0
        while w <= 320.0 {
            let o = origin(w: w, h: 32 + (w - 180) * (118.0 / 140.0))
            let center = o.x + w / 2
            if let prev = lastCenter {
                XCTAssertEqual(center, prev, accuracy: 0.01, "center moved at w=\(w)")
            }
            lastCenter = center
            w += 2
        }
        XCTAssertEqual(lastCenter!, 756.0, accuracy: 0.01,
                       "center must be exactly constant at every size")
    }
}

// MARK: - Battery: real IOKit data

final class BatteryTests: XCTestCase {
    func testEtaText() {
        XCTAssertNil(BatteryMonitor.etaText(minutes: nil))
        XCTAssertNil(BatteryMonitor.etaText(minutes: 0))
        XCTAssertNil(BatteryMonitor.etaText(minutes: -5))
        XCTAssertEqual(BatteryMonitor.etaText(minutes: 40), "~40m until full")
        XCTAssertEqual(BatteryMonitor.etaText(minutes: 84), "~1h 24m until full")
    }

    func testLiveReadingIsSane() {
        let m = BatteryMonitor()
        let exp = expectation(description: "reading")
        m.start { charge in
            XCTAssertTrue((0...1).contains(charge.level), "level must be a fraction")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNotNil(m.current, "latest reading must be stored for the menu action")
    }
}

// MARK: - Weather: condition mapping

final class WeatherTests: XCTestCase {
    func testSymbolMapping() {
        XCTAssertEqual(WeatherMonitor.symbol(for: 0).1, "Clear")
        XCTAssertEqual(WeatherMonitor.symbol(for: 2).1, "Partly Cloudy")
        XCTAssertEqual(WeatherMonitor.symbol(for: 61).1, "Rainy")
        XCTAssertEqual(WeatherMonitor.symbol(for: 71).1, "Snow")
        XCTAssertEqual(WeatherMonitor.symbol(for: 95).1, "Thunderstorm")
        XCTAssertFalse(WeatherMonitor.symbol(for: 0).0.isEmpty)
    }
}

// MARK: - Priority: ambient order + plug override

final class PriorityTests: XCTestCase {
    func testAmbientRankOrder() {
        XCTAssertLessThan(IslandCenter.rank(of: .weather(WeatherActivity(temperatureC: 20, condition: "C", symbol: "s"))),
                          IslandCenter.rank(of: .charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil))))
        XCTAssertLessThan(IslandCenter.rank(of: .charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil))),
                          IslandCenter.rank(of: .focus(FocusActivity(mode: "M"))))
        XCTAssertLessThan(IslandCenter.rank(of: .focus(FocusActivity(mode: "M"))),
                          IslandCenter.rank(of: .nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true))))
    }

    func testPresentKeepsRankOrder() {
        let c = IslandCenter()
        c.present(.weather(WeatherActivity(temperatureC: 20, condition: "C", symbol: "s")), autoDismissAfter: nil, expand: false)
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)), autoDismissAfter: nil, expand: false)
        c.present(.charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil)), autoDismissAfter: nil, expand: false)
        XCTAssertEqual(c.islands.map(\.id), ["weather", "charging", "nowPlaying"])
    }

    func testPlugOverrideAndReturn() {
        let c = IslandCenter()
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)), autoDismissAfter: nil, expand: false)
        c.present(.charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil)), autoDismissAfter: nil, expand: false)
        c.moveToTop("charging")
        XCTAssertEqual(c.islands.last?.id, "charging")
        c.applyPriorityOrder()
        XCTAssertEqual(c.islands.map(\.id), ["charging", "nowPlaying"])
    }
}

// MARK: - MediaRemote: never crash without a player

final class MediaRemoteTests: XCTestCase {
    func testMediaRemoteNeverCrashesWithoutPlayer() {
        // Must be safe to call with nothing playing / framework quirks.
        MediaRemote.sendCommand(.togglePlayPause)
        MediaRemote.getNowPlayingInfo(DispatchQueue.main) { _ in }
    }
}
