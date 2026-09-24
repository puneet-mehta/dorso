import XCTest
@testable import DorsoCore

final class SmileScoreProcessorTests: XCTestCase {

    /// A processor warmed up with `count` neutral-mouth samples.
    private func warmedUpProcessor(neutralAspect: Double = 2.0, count: Int = 50) -> SmileScoreProcessor {
        var processor = SmileScoreProcessor()
        for _ in 0..<count {
            _ = processor.ingest(aspect: neutralAspect)
        }
        return processor
    }

    /// Feed `frames` smiling frames; returns whether any confirmed a smile.
    private func feedSmile(
        _ processor: inout SmileScoreProcessor,
        aspect: Double,
        frames: Int
    ) -> Bool {
        var detected = false
        for _ in 0..<frames {
            if processor.ingest(aspect: aspect).smileDetected { detected = true }
        }
        return detected
    }

    // MARK: - mouthAspect

    func testMouthAspectFromBoundingBox() {
        // Width 0.4, height 0.2 -> aspect 2.0
        let points = [
            CGPoint(x: 0.0, y: 0.1),
            CGPoint(x: 0.2, y: 0.0),
            CGPoint(x: 0.4, y: 0.1),
            CGPoint(x: 0.2, y: 0.2)
        ]
        XCTAssertEqual(SmileScoreProcessor.mouthAspect(points: points)!, 2.0, accuracy: 0.0001)
    }

    func testMouthAspectRejectsDegenerateInput() {
        XCTAssertNil(SmileScoreProcessor.mouthAspect(points: [CGPoint(x: 0, y: 0)]))
        XCTAssertNil(SmileScoreProcessor.mouthAspect(points: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 6)))
    }

    // MARK: - Warm-up and validity

    func testNoSmileDuringWarmup() {
        var processor = SmileScoreProcessor()
        for _ in 0..<10 {
            let output = processor.ingest(aspect: 3.0)
            XCTAssertFalse(output.smileDetected)
            XCTAssertFalse(output.isValidSample)
        }
    }

    func testNilAspectIsInvalid() {
        var processor = warmedUpProcessor()
        let output = processor.ingest(aspect: nil)
        XCTAssertFalse(output.isValidSample)
        XCTAssertFalse(output.smileDetected)
    }

    // MARK: - Smile confirmation

    func testSustainedSmileConfirms() {
        var processor = warmedUpProcessor(neutralAspect: 2.0)
        // 2.0 * 1.25 = 2.5; 2.8 is clearly a smile. Needs confirmFrames.
        XCTAssertTrue(feedSmile(&processor, aspect: 2.8, frames: processor.confirmFrames))
    }

    func testBriefWideningDoesNotConfirm() {
        var processor = warmedUpProcessor(neutralAspect: 2.0)
        // Talking: short bursts of widening interleaved with neutral frames.
        for _ in 0..<20 {
            XCTAssertFalse(feedSmile(&processor, aspect: 2.8, frames: processor.confirmFrames - 1))
            _ = processor.ingest(aspect: 2.0)
        }
    }

    func testNeutralMouthNeverSmiles() {
        var processor = warmedUpProcessor(neutralAspect: 2.0)
        XCTAssertFalse(feedSmile(&processor, aspect: 2.0, frames: 60))
    }

    func testLongSmileCountsOnce() {
        var processor = warmedUpProcessor(neutralAspect: 2.0)
        var detections = 0
        // Grin for far longer than confirmFrames but less than the
        // refractory window.
        for _ in 0..<(processor.refractoryFrames / 2) {
            if processor.ingest(aspect: 2.8).smileDetected { detections += 1 }
        }
        XCTAssertEqual(detections, 1)
    }

    func testSecondSmileCountsAfterRefractoryGap() {
        var processor = warmedUpProcessor(neutralAspect: 2.0)
        XCTAssertTrue(feedSmile(&processor, aspect: 2.8, frames: processor.confirmFrames))
        // Back to neutral through the refractory window.
        for _ in 0..<processor.refractoryFrames {
            _ = processor.ingest(aspect: 2.0)
        }
        XCTAssertTrue(feedSmile(&processor, aspect: 2.8, frames: processor.confirmFrames))
    }

    func testResetClearsBaseline() {
        var processor = warmedUpProcessor()
        processor.reset()
        XCTAssertNil(processor.baseline)
        XCTAssertFalse(processor.ingest(aspect: 2.8).isValidSample)
    }
}
