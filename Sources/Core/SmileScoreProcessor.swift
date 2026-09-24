import Foundation

/// Pure smile detector fed per-frame mouth-aspect samples.
///
/// The camera detector computes a raw mouth aspect ratio (width/height of
/// the outer-lips contour) from the same Vision landmarks pass that feeds
/// blink detection; all baselining and confirmation live here so they stay
/// headless-testable (no Vision types).
///
/// Smiling widens the mouth and thins the lips, raising the aspect well
/// above its neutral value. The baseline is the rolling median, so it
/// adapts to each face; a smile must be sustained for several frames so
/// ordinary talking (rapid open/close flapping) doesn't count.
struct SmileScoreProcessor {
    struct Output: Equatable {
        /// A new smile was confirmed on this sample (at most once per
        /// refractory window - one long smile counts once).
        var smileDetected: Bool
        /// This sample counts as valid observation time.
        var isValidSample: Bool
    }

    /// Aspect must exceed baseline by this factor to look like a smile.
    var smileThresholdRatio: Double = 1.25
    /// Consecutive smiling frames required to confirm (~0.7s at 15 fps).
    var confirmFrames: Int = 10
    /// Valid samples required before the baseline is trusted (~3s at 15 fps).
    var warmupSampleCount: Int = 45
    /// Rolling window of valid aspects used for the baseline (~30s at 15 fps).
    var baselineWindowSize: Int = 450
    /// Frames after a confirmed smile before another can be counted
    /// (~10s at 15 fps).
    var refractoryFrames: Int = 150

    private var recentAspects: [Double] = []
    private var consecutiveSmilingFrames = 0
    private var framesSinceLastSmile = Int.max

    /// Neutral mouth estimate: median of the rolling window. The median is
    /// robust to the occasional smile inflating the baseline.
    var baseline: Double? {
        guard recentAspects.count >= warmupSampleCount else { return nil }
        let sorted = recentAspects.sorted()
        return sorted[sorted.count / 2]
    }

    /// Mouth aspect ratio from the outer-lips landmark points: contour
    /// bounding-box width over height. Ordering-independent, resolution-
    /// independent (points are normalized to the face bounding box).
    static func mouthAspect(points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        let height = maxY - minY
        guard height > 0 else { return nil }
        return Double((maxX - minX) / height)
    }

    /// Feed one frame's mouth aspect (nil = no face / low confidence).
    mutating func ingest(aspect: Double?) -> Output {
        if framesSinceLastSmile != Int.max {
            framesSinceLastSmile += 1
        }

        guard let aspect, aspect > 0 else {
            consecutiveSmilingFrames = 0
            return Output(smileDetected: false, isValidSample: false)
        }

        guard let baseline else {
            recentAspects.append(aspect)
            return Output(smileDetected: false, isValidSample: false)
        }

        var detected = false
        if aspect > baseline * smileThresholdRatio {
            consecutiveSmilingFrames += 1
            if consecutiveSmilingFrames == confirmFrames,
               framesSinceLastSmile >= refractoryFrames || framesSinceLastSmile == Int.max {
                detected = true
                framesSinceLastSmile = 0
            }
            // Smiling frames are deliberately kept out of the baseline so a
            // long grin doesn't teach the processor that smiling is neutral.
        } else {
            consecutiveSmilingFrames = 0
            appendToBaseline(aspect)
        }

        return Output(smileDetected: detected, isValidSample: true)
    }

    mutating func reset() {
        recentAspects.removeAll()
        consecutiveSmilingFrames = 0
        framesSinceLastSmile = Int.max
    }

    private mutating func appendToBaseline(_ aspect: Double) {
        recentAspects.append(aspect)
        if recentAspects.count > baselineWindowSize {
            recentAspects.removeFirst(recentAspects.count - baselineWindowSize)
        }
    }
}
