import Compression
import XCTest
@testable import Halo

// MARK: - HaloCenter: live activities

final class HaloCenterTests: XCTestCase {

    func testStartsIdle() {
        let c = HaloCenter()
        XCTAssertTrue(c.activities.isEmpty)
        XCTAssertNil(c.expandedId)
    }

    func testCollapseKeepsActivityAlive() {
        let c = HaloCenter()
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: nil, expand: true)
        XCTAssertEqual(c.expandedId, "notification")
        c.collapse("notification")
        XCTAssertNil(c.expandedId)
        XCTAssertEqual(c.activities.count, 1, "collapse must keep the activity, unlike dismiss")
    }

    func testCollapseAfterAutoSettlesCardToPill() {
        let c = HaloCenter()
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: nil, expand: true, collapseAfter: 0.5)
        XCTAssertEqual(c.expandedId, "notification")
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertNil(c.expandedId, "card must settle back to pill")
        XCTAssertEqual(c.activities.count, 1, "activity must survive the settle")
    }

    func testAdminOverrideSurvivesNormalCollapseAndKeepsOpenCodeSelected() {
        let c = HaloCenter()
        c.present(.openCode(OpenCodeActivity(
            sessions: [], selectedSessionID: nil, messages: [], connection: .connected,
            pendingPermission: nil, errorMessage: nil
        )), autoDismissAfter: nil, intent: .expand(.user))

        XCTAssertEqual(c.expandedId, "openCode")
        XCTAssertEqual(c.manualOverrideID, "openCode")
        c.collapse("openCode")
        XCTAssertNil(c.expandedId, "pointer exit must minimize the expanded card")
        XCTAssertEqual(c.manualOverrideID, "openCode")

        c.present(.codex(CodexActivity(
            chats: [], selectedChatID: nil, messages: [], connection: .connected,
            pendingApproval: nil, errorMessage: nil
        )), autoDismissAfter: nil, intent: .update)
        XCTAssertEqual(c.manualOverrideID, "openCode", "passive Codex updates must not replace the override")
        XCTAssertFalse(c.canAutomaticallyExpand("codex"), "Codex must not take over the selected OpenCode pill")
        XCTAssertTrue(c.canAutomaticallyExpand("openCode"))

        c.toggleExpandTop()
        XCTAssertEqual(c.expandedId, "openCode", "the selected pill must reopen OpenCode")
        c.collapse("openCode")

        c.present(.codex(CodexActivity(
            chats: [], selectedChatID: nil, messages: [], connection: .connected,
            pendingApproval: nil, errorMessage: nil
        )), autoDismissAfter: nil, intent: .expand(.user))
        XCTAssertEqual(c.manualOverrideID, "codex", "a new explicit choice must replace the old override")
        XCTAssertEqual(c.expandedId, "codex")
    }

    func testNewerCollapseScheduleSupersedesOlderCallback() {
        let c = HaloCenter()
        let first = NotificationActivity(appName: "A", sender: "B", body: "First", icon: "m")
        let second = NotificationActivity(appName: "A", sender: "B", body: "Second", icon: "m")
        c.present(.notification(first), autoDismissAfter: nil, expand: true, collapseAfter: 0.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        c.present(.notification(second), autoDismissAfter: nil, expand: true, collapseAfter: 0.6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(c.expandedId, "notification", "an older delayed collapse must not win")

        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        XCTAssertNil(c.expandedId, "the newest collapse schedule should still settle the card")
    }

    func testQuietMonitorUpdatesNeverHijack() {
        let c = HaloCenter()
        c.present(.weather(WeatherActivity(temperatureC: 15, condition: "Clear", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        XCTAssertNil(c.expandedId, "passive updates must not steal the halo")
        XCTAssertEqual(c.activities.count, 1)
        // A repeat refresh must not expand either.
        c.present(.weather(WeatherActivity(temperatureC: 16, condition: "Clear", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        XCTAssertNil(c.expandedId)
        XCTAssertEqual(c.activities.count, 1, "same id must update in place, not duplicate")
    }

    func testAutomaticExpansionCannotReplaceAnActiveProvider() {
        let c = HaloCenter()
        c.present(.openCode(OpenCodeActivity(
            sessions: [], selectedSessionID: nil, messages: [], connection: .connected,
            pendingPermission: nil, errorMessage: nil
        )), autoDismissAfter: nil, intent: .expand(.user))

        XCTAssertEqual(c.manualOverrideID, "openCode")
        XCTAssertFalse(c.canAutomaticallyExpand("codex"))
        XCTAssertTrue(c.canAutomaticallyExpand("openCode"))

        c.toggleExpand("codex")
        XCTAssertEqual(c.expandedId, "openCode", "a generic pill tap must not replace a manual selection")

        c.collapse("openCode")
        XCTAssertNil(c.expandedId)
        XCTAssertEqual(c.manualOverrideID, "openCode")
        XCTAssertFalse(c.canAutomaticallyExpand("codex"))
        XCTAssertTrue(c.canAutomaticallyExpand("openCode"))
    }

    func testDismissFallsBackToPreviousActivity() {
        let c = HaloCenter()
        c.present(.weather(WeatherActivity(temperatureC: 15, condition: "C", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: nil, expand: true)
        c.dismiss("notification")
        XCTAssertEqual(c.expandedId, "weather")
    }

    func testDismissAll() {
        let c = HaloCenter()
        c.present(.weather(WeatherActivity(temperatureC: 15, condition: "C", symbol: "s")),
                  autoDismissAfter: nil, expand: false)
        c.dismissAll()
        XCTAssertTrue(c.activities.isEmpty)
        XCTAssertNil(c.expandedId)
    }

    func testActivityStackCapped() {
        let c = HaloCenter()
        for i in 0..<6 {
            c.present(.notification(NotificationActivity(appName: "A\(i)", sender: "B", body: "C", icon: "m")),
                      autoDismissAfter: nil, expand: false)
            // Unique ids to force growth.
            c.dismiss("notification")
            c.present(.focus(FocusActivity(mode: "M\(i)")), autoDismissAfter: nil, expand: false)
        }
        XCTAssertLessThanOrEqual(c.activities.count, 4)
    }

    func testAutoDismissRemoves() {
        let c = HaloCenter()
        c.present(.notification(NotificationActivity(appName: "A", sender: "B", body: "C", icon: "m")),
                  autoDismissAfter: 0.5, expand: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(c.activities.isEmpty)
    }

    func testNowPlayingProgressMath() {
        let n = NowPlayingActivity(title: "T", artist: "A", isPlaying: true, elapsed: 60, duration: 240)
        XCTAssertEqual(n.progress, 0.25, accuracy: 0.001)
        let zero = NowPlayingActivity(title: "T", artist: "A", isPlaying: false)
        XCTAssertEqual(zero.progress, 0)
    }

    func testPauseProgressUpdateStopsPlaybackState() {
        let c = HaloCenter()
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true,
                                                  elapsed: 60, duration: 240)),
                  autoDismissAfter: nil, expand: false)
        c.updateNowPlayingProgress(elapsed: 61, duration: 240, isPlaying: false)
        guard case .nowPlaying(let n) = c.activities.first else {
            return XCTFail("expected the nowPlaying activity")
        }
        XCTAssertFalse(n.isPlaying, "pause state must reach the collapsed playback indicator")
    }
}

// MARK: - Playback indicator regression

final class SpectrumBarsTests: XCTestCase {
    func testPausedPlaybackUsesStillIndicator() {
        XCTAssertEqual(SpectrumBars.mode(for: false), .still)
    }

    func testPlayingPlaybackUsesAnimatedIndicator() {
        XCTAssertEqual(SpectrumBars.mode(for: true), .animated)
    }
}

// MARK: - Positioning: the anti-slide contract

final class PositioningTests: XCTestCase {
    // Built-in 14" geometry: 1512x982, menu bar 32, top-surface gap 663..848.
    let topGapMin = 663.0, topGapMax = 848.0
    let midX = 756.0, menuBar = 32.0, maxY = 982.0

    func origin(w: Double, h: Double) -> CGPoint {
        HaloWindowController.haloOrigin(width: w, height: h,
                                           screenMidX: midX, menuBarHeight: menuBar,
                                           screenMaxY: maxY)
    }

    func testIdlePillSitsAtTopSurface() {
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

    func testConfiguredNotchSizeStaysInsideWindowAndPinnedToTop() {
        let size = HaloNotchMetrics.expandedSize(widthScale: 1.25, heightScale: 1.35)
        XCTAssertLessThanOrEqual(size.width, HaloNotchMetrics.windowSize.width)
        XCTAssertLessThanOrEqual(size.height, HaloNotchMetrics.windowSize.height)

        let o = origin(w: size.width, h: size.height)
        XCTAssertEqual(o.y + size.height, maxY, accuracy: 0.001)
        XCTAssertEqual(o.x + size.width / 2, midX, accuracy: 0.001)
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

    func testTimeRemainingUsesTheCurrentPowerDirection() {
        XCTAssertEqual(
            BatteryMonitor.timeRemainingText(minutes: 84, isCharging: true),
            "~1h 24m until full"
        )
        XCTAssertEqual(
            BatteryMonitor.timeRemainingText(minutes: 84, isCharging: false),
            "~1h 24m remaining"
        )
        XCTAssertNil(
            BatteryMonitor.timeRemainingText(minutes: 84, isCharging: true, isFullyCharged: true)
        )
    }

    func testHealthPercentIsDerivedFromFullAndDesignCapacity() {
        XCTAssertEqual(BatteryMonitor.healthPercent(maxCapacity: 4_700, designCapacity: 5_000), 94)
        XCTAssertEqual(BatteryMonitor.healthPercent(maxCapacity: 5_200, designCapacity: 5_000), 100)
        XCTAssertNil(BatteryMonitor.healthPercent(maxCapacity: 4_700, designCapacity: nil))
        XCTAssertNil(BatteryMonitor.healthPercent(maxCapacity: 4_700, designCapacity: 0))
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
        XCTAssertLessThan(HaloCenter.rank(of: .weather(WeatherActivity(temperatureC: 20, condition: "C", symbol: "s"))),
                          HaloCenter.rank(of: .charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil))))
        XCTAssertLessThan(HaloCenter.rank(of: .charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil))),
                          HaloCenter.rank(of: .calendar(CalendarActivity(items: []))))
        XCTAssertLessThan(HaloCenter.rank(of: .calendar(CalendarActivity(items: []))),
                          HaloCenter.rank(of: .nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true))))
        XCTAssertLessThan(HaloCenter.rank(of: .charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil))),
                          HaloCenter.rank(of: .focus(FocusActivity(mode: "M"))))
        XCTAssertLessThan(HaloCenter.rank(of: .focus(FocusActivity(mode: "M"))),
                          HaloCenter.rank(of: .nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true))))
    }

    func testPresentKeepsRankOrder() {
        let c = HaloCenter()
        c.present(.weather(WeatherActivity(temperatureC: 20, condition: "C", symbol: "s")), autoDismissAfter: nil, expand: false)
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)), autoDismissAfter: nil, expand: false)
        c.present(.charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil)), autoDismissAfter: nil, expand: false)
        c.present(.calendar(CalendarActivity(items: [])), autoDismissAfter: nil, expand: false)
        XCTAssertEqual(c.activities.map(\.id), ["weather", "charging", "calendar", "nowPlaying"])
    }

    func testExplicitCalendarSelectionSurvivesAFullActivityStack() {
        let c = HaloCenter()
        c.present(.codex(CodexActivity(
            chats: [], selectedChatID: nil, messages: [], connection: .connected,
            pendingApproval: nil, errorMessage: nil
        )), autoDismissAfter: nil, intent: .update)
        c.present(.openCode(OpenCodeActivity(
            sessions: [], selectedSessionID: nil, messages: [], connection: .connected,
            pendingPermission: nil, errorMessage: nil
        )), autoDismissAfter: nil, intent: .update)
        c.present(.claudeCode(ClaudeCodeActivity(
            sessions: [], selectedSessionID: nil, messages: [], connection: .connected,
            errorMessage: nil
        )), autoDismissAfter: nil, intent: .update)
        c.present(.nowPlaying(NowPlayingActivity(
            title: "Track", artist: "Artist", isPlaying: false
        )), autoDismissAfter: nil, intent: .update)

        c.present(
            .calendar(CalendarActivity(items: [])),
            autoDismissAfter: nil,
            intent: .expand(.user)
        )

        XCTAssertEqual(c.activities.count, 4)
        XCTAssertTrue(c.activities.contains { $0.id == "calendar" })
        XCTAssertEqual(c.expandedId, "calendar")
    }

    func testPlugOverrideAndReturn() {
        let c = HaloCenter()
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)), autoDismissAfter: nil, expand: false)
        c.present(.charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil)), autoDismissAfter: nil, expand: false)
        c.moveToTop("charging")
        XCTAssertEqual(c.activities.last?.id, "charging")
        c.applyPriorityOrder()
        XCTAssertEqual(c.activities.map(\.id), ["charging", "nowPlaying"])
    }

    func testPriorityRestoreKeepsTheCurrentlyExpandedCard() {
        let c = HaloCenter()
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)), autoDismissAfter: nil, expand: true)
        c.present(.charging(ChargingActivity(level: 0.5, isPluggedIn: true, timeRemainingText: nil)), autoDismissAfter: nil, expand: false)

        c.moveToTop("charging")
        c.applyPriorityOrder()

        XCTAssertEqual(c.expandedId, "nowPlaying", "reordering must not replace the card being viewed")
    }
}

// MARK: - Notification parsing

final class NotificationParseTests: XCTestCase {
    private func samplePayload() -> Data {
        let req: [String: Any] = [
            "titl": "Cutu Prii", "subt": "2 messages",
            "body": "Bitch behaviour", "cate": "x",
        ]
        let plist: [String: Any] = [
            "app": "com.apple.MobileSMS", "date": 810576430.6, "req": req,
        ]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func testParsesTitleSubtitleBody() {
        let note = NotificationMonitor.parse(data: samplePayload(), appIdentifier: "com.apple.MobileSMS")!
        XCTAssertEqual(note.title, "Cutu Prii")
        XCTAssertEqual(note.subtitle, "2 messages")
        XCTAssertEqual(note.body, "Bitch behaviour")
        XCTAssertEqual(note.appIdentifier, "com.apple.MobileSMS")
    }

    func testRejectsGarbage() {
        XCTAssertNil(NotificationMonitor.parse(data: Data([0, 1, 2, 3]), appIdentifier: "x"))
    }
}

// MARK: - Up Next queue

final class UpNextTests: XCTestCase {
    func testParsesNeighborRecords() {
        let text = "PLID123\u{1E}101\u{1F}111\u{1F}Song A\u{1F}Artist A\u{1E}102\u{1F}112\u{1F}Song B\u{1F}Artist B\u{1E}103\u{1F}113\u{1F}Song C\u{1F}Artist C"
        let (pid, items) = MusicAppMonitor.parseUpNext(text)
        XCTAssertEqual(pid, "PLID123")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "Song A")
        XCTAssertEqual(items[0].artist, "Artist A")
        XCTAssertEqual(items[0].playlistID, "PLID123")
        XCTAssertEqual(items[0].trackIndex, 101)
        XCTAssertEqual(items[2].artist, "Artist C")
    }

    func testSkipsMalformedAndUnnamed() {
        // Record 2 lacks the artist field; record 3 has an empty title.
        let text = "PLID\u{1E}101\u{1F}1\u{1F}Song A\u{1F}Artist A\u{1E}102\u{1F}2\u{1F}Song B\u{1E}103\u{1F}3\u{1F}\u{1F}Artist C\u{1E}104\u{1F}4\u{1F}Song D\u{1F}Artist D"
        let (_, items) = MusicAppMonitor.parseUpNext(text)
        XCTAssertEqual(items.map(\.title), ["Song A", "Song D"])
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(MusicAppMonitor.parseUpNext("").1.isEmpty)
        XCTAssertTrue(MusicAppMonitor.parseUpNext("NOQUEUE").1.isEmpty)
    }

    func testQueueAttachesSilently() {
        let c = HaloCenter()
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)),
                  autoDismissAfter: nil, expand: true)
        c.collapse("nowPlaying") // card settled back to pill
        c.updateNowPlayingQueue([UpNextItem(title: "Next", artist: "Someone")])
        XCTAssertNil(c.expandedId, "queue attach must never expand the halo")
        XCTAssertEqual(c.activities.count, 1, "queue attach must not add or remove activities")
        guard case .nowPlaying(let n) = c.activities[0] else {
            return XCTFail("expected the nowPlaying activity")
        }
        XCTAssertEqual(n.upNext.count, 1)
        XCTAssertEqual(n.upNext[0].title, "Next")
    }

    func testQueueSkipsWriteWhenUnchanged() {
        let c = HaloCenter()
        c.present(.nowPlaying(NowPlayingActivity(title: "T", artist: "A", isPlaying: true)),
                  autoDismissAfter: nil, expand: false)
        let items = [UpNextItem(title: "Next", artist: "Someone")]
        c.updateNowPlayingQueue(items)
        c.updateNowPlayingQueue(items) // duplicate write
        guard case .nowPlaying(let n) = c.activities[0] else {
            return XCTFail("expected the nowPlaying activity")
        }
        XCTAssertEqual(n.upNext, items, "same queue must not duplicate or corrupt")
    }

    func testRecentSurvivesTrackChange() {
        let c = HaloCenter()
        let recents = [PlaybackHistoryMonitor.Track(title: "Old Song", artist: "X", storeID: nil, url: nil, artworkURL: nil, artworkData: nil, date: Date())]
        c.present(.nowPlaying(NowPlayingActivity(title: "First", artist: "A", isPlaying: true)),
                  autoDismissAfter: nil, expand: false)
        c.updateNowPlayingRecent(recents)
        // Track change: fresh card arrives with empty recent — cache must re-attach.
        c.present(.nowPlaying(NowPlayingActivity(title: "Second", artist: "B", isPlaying: true)),
                  autoDismissAfter: nil, expand: false)
        guard case .nowPlaying(let n) = c.activities.last else {
            return XCTFail("expected the nowPlaying activity")
        }
        XCTAssertEqual(n.recent, recents, "fallback rail must survive the fresh card on track change")
    }
}

// MARK: - Playback history (session archives)

final class PlaybackHistoryTests: XCTestCase {
    /// Raw-deflate body wrapped in a minimal gzip container, exactly the
    /// shape Music writes (FLG=0; our decoder ignores the trailer).
    private func gzipWrap(_ raw: Data) -> Data {
        var body = raw
        let cap = raw.count * 2 + 64
        var dst = [UInt8](repeating: 0, count: cap)
        let n = compression_encode_buffer(&dst, cap, [UInt8](body), body.count, nil,
                                          compression_algorithm(rawValue: 0x205))
        body = Data(dst.prefix(n))
        var gz = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0x00])
        gz += body
        gz += Data(repeating: 0, count: 8) // CRC32 + ISIZE (unused by our decoder)
        return gz
    }

    /// Matches the verified live shape: top f1 = window id string,
    /// top f2 = nested item { f1 title, f6 album, f7 artist }.
    private func protobuf(title: String, artist: String) -> Data {
        func lenDelimited(_ n: Int, _ payload: Data) -> Data {
            var d = Data([UInt8(n << 3 | 2)])
            var len = payload.count
            while len >= 0x80 { d.append(UInt8(len & 0x7f) | 0x80); len >>= 7 }
            d.append(UInt8(len))
            d.append(payload)
            return d
        }
        var item = Data()
        item += lenDelimited(1, Data(title.utf8))
        item += lenDelimited(6, Data("Some Album".utf8))
        item += lenDelimited(7, Data(artist.utf8))
        item += lenDelimited(8, Data()) // zero-length field: real sessions contain these
        var d = Data()
        d += lenDelimited(1, Data("8600::8610".utf8))
        d += lenDelimited(2, item)
        return d
    }

    func testProtobufParsesTitleArtist() {
        let (t, a) = PlaybackHistoryMonitor.parseProtobuf(url: protobuf(title: "Dracula", artist: "Tame Impala"))!
        XCTAssertEqual(t, "Dracula")
        XCTAssertEqual(a, "Tame Impala")
    }

    func testProtobufRejectsGarbage() {
        XCTAssertNil(PlaybackHistoryMonitor.parseProtobuf(url: Data([0xff, 0xff, 0xff])))
    }

    func testGunzipDecodesRealGzipShape() {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let gz = gzipWrap(payload)
        XCTAssertNil(PlaybackHistoryMonitor.gunzip(url: URL(fileURLWithPath: "/nonexistent"))) // sanity
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! gz.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let decoded = PlaybackHistoryMonitor.gunzip(url: tmp)
        XCTAssertEqual(String(data: decoded ?? Data(), encoding: .utf8), "{\"hello\":\"world\"}")
    }

    func testExtractsJSONWithEscapesAndPrefixBytes() {
        let json = #"{"id":"1645617485","attributes":{"url":"https:\/\/music.apple.com\/in\/album\/wannabe\/1645617160?i=1645617485","playParams":{"id":"1645617485","kind":"song"}}}"#
        let blob = Data([0x00, 0x05]) + Data(json.utf8) + Data([0x00, 0x01])
        let obj = PlaybackHistoryMonitor.extractFirstJSON(url: blob) as? [String: Any]
        let attrs = obj?["attributes"] as? [String: Any]
        XCTAssertEqual((attrs?["playParams"] as? [String: Any])?["id"] as? String, "1645617485")
    }

    func testParseSessionFromSyntheticArchive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try gzipWrap(protobuf(title: "Loser", artist: "Tame Impala")).write(to: dir.appendingPathComponent("contentItem.protobuf.gz"))
        let json = #"{"id":"77","attributes":{"name":"Loser","playParams":{"id":"77"},"url":"https:\/\/music.apple.com\/x\/77","artwork":{"url":"https:\/\/is1-ssl.mzstatic.com\/image\/thumb\/Music\/v4\/abc\/196589493194.jpg\/{w}x{h}bb.jpg"}}}"#
        try gzipWrap(Data(json.utf8)).write(to: dir.appendingPathComponent("itemPayload.opackCoder.gz"))
        let track = try XCTUnwrap(PlaybackHistoryMonitor.parseSession(dir))
        XCTAssertEqual(track.title, "Loser")
        XCTAssertEqual(track.artist, "Tame Impala")
        XCTAssertEqual(track.storeID, "77")
        XCTAssertEqual(track.musicAppURL?.absoluteString, "music://music.apple.com/x/77")
        XCTAssertEqual(track.artworkURL, "https://is1-ssl.mzstatic.com/image/thumb/Music/v4/abc/196589493194.jpg/64x64bb.jpg")
    }

    func testParseSessionSkipsArchiveWithoutContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(PlaybackHistoryMonitor.parseSession(dir))
    }

    func testSizedArtworkURL() {
        // {w}x{h} template from itemPayload JSON
        XCTAssertEqual(
            PlaybackHistoryMonitor.sizedArtworkURL("https://is1-ssl.mzstatic.com/image/thumb/x/1.jpg/{w}x{h}bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/x/1.jpg/64x64bb.jpg")
        // fixed size from the protobuf
        XCTAssertEqual(
            PlaybackHistoryMonitor.sizedArtworkURL("https://is1-ssl.mzstatic.com/image/thumb/x/1.jpg/800x800bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/x/1.jpg/64x64bb.jpg")
        // non-CDN URLs are rejected
        XCTAssertNil(PlaybackHistoryMonitor.sizedArtworkURL("https://evil.example.com/1.jpg"))
    }

    func testFindArtworkURLInProtobuf() {
        let blob = Data("\n\u{10}8621::8629\n\u{1F}Still Breathing\u{11}https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/x/00602567892410.rgb.jpg/800x800bb.jpg\n".utf8)
        XCTAssertEqual(
            PlaybackHistoryMonitor.findArtworkURL(in: blob),
            "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/x/00602567892410.rgb.jpg/64x64bb.jpg")
        XCTAssertNil(PlaybackHistoryMonitor.findArtworkURL(in: Data("no urls here".utf8)))
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
