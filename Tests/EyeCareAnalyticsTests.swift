import XCTest
@testable import DorsoCore

final class EyeCareAnalyticsTests: XCTestCase {

    private func makeManager(fileURL: URL, queue: DispatchQueue) -> AnalyticsManager {
        AnalyticsManager(
            fileURL: fileURL,
            calendar: Calendar(identifier: .gregorian),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            persistenceQueue: queue
        )
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("analytics.json")
    }

    // MARK: - Back-compat decoding

    func testLegacyJSONWithoutEyeCareFieldsDecodes() throws {
        // Pre-eye-care analytics.json entries lack the new keys entirely.
        let legacyJSON = """
        {"date": 700000000, "totalSeconds": 3600, "slouchSeconds": 300, "slouchCount": 7}
        """
        let decoder = JSONDecoder()
        let stats = try decoder.decode(DailyStats.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(stats.slouchCount, 7)
        XCTAssertEqual(stats.blinkNudgeCount, 0)
        XCTAssertEqual(stats.restBreaksCompleted, 0)
    }

    func testEyeCareFieldsRoundTrip() throws {
        var stats = DailyStats(date: Date(), totalSeconds: 100, slouchSeconds: 10, slouchCount: 1)
        stats.blinkNudgeCount = 4
        stats.restBreaksCompleted = 9
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(DailyStats.self, from: data)
        XCTAssertEqual(decoded.blinkNudgeCount, 4)
        XCTAssertEqual(decoded.restBreaksCompleted, 9)
    }

    // MARK: - Recording

    func testRecordBlinkNudgeIncrementsToday() {
        let queue = DispatchQueue(label: "test.eyecare.analytics")
        let manager = makeManager(fileURL: tempFileURL(), queue: queue)
        manager.recordBlinkNudge()
        manager.recordBlinkNudge()
        queue.sync {}
        XCTAssertEqual(manager.todayStats.blinkNudgeCount, 2)
        XCTAssertEqual(manager.todayStats.restBreaksCompleted, 0)
    }

    func testRecordRestBreakCompletedIncrementsToday() {
        let queue = DispatchQueue(label: "test.eyecare.analytics")
        let manager = makeManager(fileURL: tempFileURL(), queue: queue)
        manager.recordRestBreakCompleted()
        queue.sync {}
        XCTAssertEqual(manager.todayStats.restBreaksCompleted, 1)
        XCTAssertEqual(manager.todayStats.blinkNudgeCount, 0)
    }

    func testMarketingDataIncludesEyeCareValues() {
        let queue = DispatchQueue(label: "test.eyecare.analytics")
        let manager = makeManager(fileURL: tempFileURL(), queue: queue)
        manager.injectMarketingData()
        queue.sync {}
        XCTAssertGreaterThan(manager.todayStats.restBreaksCompleted, 0)
    }
}
