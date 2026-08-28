import Foundation

/// Pure blink detector fed per-frame Eye Aspect Ratio (EAR) samples.
///
/// The camera detector computes a raw EAR from Vision eye landmarks and feeds
/// it here; all thresholding, baselining, and blink confirmation live in this
/// struct so they stay headless-testable with synthetic traces (no Vision
/// types anywhere).
///
/// Design:
/// - Baseline "open eye" EAR is the 90th percentile of recent valid samples,
///   so it auto-adapts to each user, their glasses, and lighting — no
///   calibration step. Requires a warm-up before any blink is reported.
/// - A blink is a short dip below a fraction of baseline (1...maxDipFrames
///   consecutive frames) followed by recovery. A sustained dip (looking down
///   at the keyboard, lids drooped) is neither a blink nor valid "staring"
///   evidence — those frames are reported as invalid.
struct BlinkEARProcessor {
    struct Output: Equatable {
        /// A completed blink was confirmed on this sample.
        var blinkDetected: Bool
        /// This sample counts as valid observation time for rate statistics.
        var isValidSample: Bool
    }

    /// Fraction of baseline EAR below which the eye counts as closed.
    var closedThresholdRatio: Double = 0.55
    /// Maximum consecutive closed frames that still count as a blink
    /// (~266 ms at 15 fps). Longer dips are treated as invalid (drooped gaze).
    var maxDipFrames: Int = 4
    /// Number of valid samples required before baseline is trusted (~3 s at
    /// 15 fps).
    var warmupSampleCount: Int = 45
    /// Rolling window of valid EARs used for the baseline (~30 s at 15 fps).
    var baselineWindowSize: Int = 450

    private var recentEARs: [Double] = []
    private var consecutiveClosedFrames = 0

    /// Robust open-eye estimate: 90th percentile of the rolling window.
    var baseline: Double? {
        guard recentEARs.count >= warmupSampleCount else { return nil }
        let sorted = recentEARs.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.9))
        return sorted[index]
    }

    /// Eye Aspect Ratio for one eye from its landmark points.
    ///
    /// Vision's `leftEye`/`rightEye` regions are closed polygons around the
    /// eye contour. Rather than assuming a fixed landmark ordering, use the
    /// bounding box: height/width of the contour is a stable openness proxy
    /// at webcam resolutions and is ordering-independent.
    static func eyeAspectRatio(points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return nil }
        let width = maxX - minX
        guard width > 0 else { return nil }
        return Double((maxY - minY) / width)
    }

    /// Feed one frame's EAR (nil = no face / low confidence) and get back
    /// whether a blink completed and whether the sample is valid.
    mutating func ingest(ear: Double?) -> Output {
        guard let ear, ear > 0 else {
            // Lost the face: an in-flight short dip can't be confirmed.
            consecutiveClosedFrames = 0
            return Output(blinkDetected: false, isValidSample: false)
        }

        guard let baseline else {
            // Warm-up: accumulate baseline data, report invalid.
            appendToBaseline(ear)
            return Output(blinkDetected: false, isValidSample: false)
        }

        if ear < baseline * closedThresholdRatio {
            consecutiveClosedFrames += 1
            // A short dip in progress is still valid observation; a sustained
            // dip (drooped gaze) stops counting as evidence either way.
            let stillPlausibleBlink = consecutiveClosedFrames <= maxDipFrames
            return Output(blinkDetected: false, isValidSample: stillPlausibleBlink)
        }

        // Eye open. Closed dips of 1...maxDipFrames frames confirm as a blink.
        let dipFrames = consecutiveClosedFrames
        consecutiveClosedFrames = 0
        appendToBaseline(ear)
        let blink = dipFrames >= 1 && dipFrames <= maxDipFrames
        return Output(blinkDetected: blink, isValidSample: true)
    }

    mutating func reset() {
        recentEARs.removeAll()
        consecutiveClosedFrames = 0
    }

    private mutating func appendToBaseline(_ ear: Double) {
        recentEARs.append(ear)
        if recentEARs.count > baselineWindowSize {
            recentEARs.removeFirst(recentEARs.count - baselineWindowSize)
        }
    }
}
