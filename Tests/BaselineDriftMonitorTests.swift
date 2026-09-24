import XCTest
@testable import DorsoCore

final class BaselineDriftMonitorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeMonitor() -> BaselineDriftMonitor {
        var monitor = BaselineDriftMonitor()
        monitor.windowSeconds = 30
        monitor.maxWobble = 0.03
        return monitor
    }

    func testStableFarOutsideReanchorsAfterWindow() {
        var monitor = makeMonitor()
        var result: CGFloat?
        // Rock-steady position far outside the band for 31 seconds (lid tilt).
        for second in 0...31 {
            result = monitor.ingest(
                y: 0.42 + CGFloat(second % 3) * 0.001,
                at: t0.addingTimeInterval(TimeInterval(second)),
                isFarOutside: true
            )
            if result != nil { break }
        }
        let stable = try! XCTUnwrap(result)
        XCTAssertEqual(stable, 0.421, accuracy: 0.002)
    }

    func testWanderingReadingsDoNotReanchor() {
        var monitor = makeMonitor()
        // Far outside but bobbing by 0.08 - a human slouching, not a camera.
        for second in 0...60 {
            let wobble = CGFloat(second % 2) * 0.08
            XCTAssertNil(monitor.ingest(
                y: 0.40 + wobble,
                at: t0.addingTimeInterval(TimeInterval(second)),
                isFarOutside: true
            ))
        }
    }

    func testInBandReadingResetsWindow() {
        var monitor = makeMonitor()
        for second in 0...20 {
            _ = monitor.ingest(y: 0.42, at: t0.addingTimeInterval(TimeInterval(second)), isFarOutside: true)
        }
        // Back in band: window resets.
        XCTAssertNil(monitor.ingest(y: 0.55, at: t0.addingTimeInterval(21), isFarOutside: false))
        // Far outside again needs a full fresh window.
        for second in 22...40 {
            XCTAssertNil(monitor.ingest(
                y: 0.42,
                at: t0.addingTimeInterval(TimeInterval(second)),
                isFarOutside: true
            ))
        }
    }

    func testShortExcursionNeverTriggers() {
        var monitor = makeMonitor()
        for second in 0...20 {
            XCTAssertNil(monitor.ingest(
                y: 0.42,
                at: t0.addingTimeInterval(TimeInterval(second)),
                isFarOutside: true
            ))
        }
    }
}
