import XCTest
@testable import DorsoCore

final class BlinkEARProcessorTests: XCTestCase {

    // MARK: - Helpers

    /// A processor warmed up with `count` open-eye samples at the given EAR.
    private func warmedUpProcessor(openEAR: Double = 0.3, count: Int = 50) -> BlinkEARProcessor {
        var processor = BlinkEARProcessor()
        for _ in 0..<count {
            _ = processor.ingest(ear: openEAR)
        }
        return processor
    }

    // MARK: - eyeAspectRatio

    func testEyeAspectRatioFromBoundingBox() {
        // 4-point diamond: width 0.2, height 0.1 -> EAR 0.5
        let points = [
            CGPoint(x: 0.0, y: 0.05),
            CGPoint(x: 0.1, y: 0.0),
            CGPoint(x: 0.2, y: 0.05),
            CGPoint(x: 0.1, y: 0.1)
        ]
        XCTAssertEqual(BlinkEARProcessor.eyeAspectRatio(points: points)!, 0.5, accuracy: 0.0001)
    }

    func testEyeAspectRatioRejectsTooFewPoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertNil(BlinkEARProcessor.eyeAspectRatio(points: points))
    }

    func testEyeAspectRatioRejectsZeroWidth() {
        let points = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 6)
        XCTAssertNil(BlinkEARProcessor.eyeAspectRatio(points: points))
    }

    // MARK: - Warm-up

    func testNoBlinkReportedDuringWarmup() {
        var processor = BlinkEARProcessor()
        for _ in 0..<10 {
            let output = processor.ingest(ear: 0.3)
            XCTAssertFalse(output.blinkDetected)
            XCTAssertFalse(output.isValidSample)
        }
    }

    func testSamplesBecomeValidAfterWarmup() {
        var processor = warmedUpProcessor()
        let output = processor.ingest(ear: 0.3)
        XCTAssertTrue(output.isValidSample)
        XCTAssertFalse(output.blinkDetected)
    }

    // MARK: - Blink detection

    func testCleanBlinkDetected() {
        var processor = warmedUpProcessor(openEAR: 0.3)
        // Two closed frames (EAR well below 0.55 * baseline) then reopen.
        XCTAssertFalse(processor.ingest(ear: 0.05).blinkDetected)
        XCTAssertFalse(processor.ingest(ear: 0.05).blinkDetected)
        let reopened = processor.ingest(ear: 0.3)
        XCTAssertTrue(reopened.blinkDetected)
        XCTAssertTrue(reopened.isValidSample)
    }

    func testSingleFrameDipCountsAsBlink() {
        var processor = warmedUpProcessor(openEAR: 0.3)
        _ = processor.ingest(ear: 0.05)
        XCTAssertTrue(processor.ingest(ear: 0.3).blinkDetected)
    }

    func testSustainedDroopIsNotABlink() {
        var processor = warmedUpProcessor(openEAR: 0.3)
        // Closed for far longer than maxDipFrames (drooped gaze).
        for i in 0..<10 {
            let output = processor.ingest(ear: 0.05)
            XCTAssertFalse(output.blinkDetected)
            if i >= processor.maxDipFrames {
                XCTAssertFalse(output.isValidSample, "Frame \(i) of a sustained droop must be invalid")
            }
        }
        // Reopening after a droop must not count as a blink.
        XCTAssertFalse(processor.ingest(ear: 0.3).blinkDetected)
    }

    func testOpenEyesNeverBlink() {
        var processor = warmedUpProcessor(openEAR: 0.3)
        for _ in 0..<30 {
            let output = processor.ingest(ear: 0.3)
            XCTAssertFalse(output.blinkDetected)
            XCTAssertTrue(output.isValidSample)
        }
    }

    // MARK: - Invalid frames

    func testNilEARIsInvalidAndCancelsDip() {
        var processor = warmedUpProcessor(openEAR: 0.3)
        _ = processor.ingest(ear: 0.05)
        let lost = processor.ingest(ear: nil)
        XCTAssertFalse(lost.isValidSample)
        XCTAssertFalse(lost.blinkDetected)
        // The interrupted dip must not resolve into a blink on reopen.
        XCTAssertFalse(processor.ingest(ear: 0.3).blinkDetected)
    }

    func testResetClearsBaseline() {
        var processor = warmedUpProcessor()
        processor.reset()
        XCTAssertNil(processor.baseline)
        XCTAssertFalse(processor.ingest(ear: 0.3).isValidSample)
    }

    // MARK: - Baseline adaptation

    func testBaselineTracksNarrowerEyes() {
        // A user whose open-eye EAR is 0.15 must still register blinks.
        var processor = warmedUpProcessor(openEAR: 0.15)
        _ = processor.ingest(ear: 0.04)
        XCTAssertTrue(processor.ingest(ear: 0.15).blinkDetected)
    }
}
