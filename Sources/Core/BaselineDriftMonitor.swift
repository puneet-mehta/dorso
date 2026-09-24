import Foundation

/// Detects camera-geometry drift (a tilted MacBook lid, a nudged external
/// camera) so the posture baseline can heal itself mid-session.
///
/// A lid tilt shifts the user's apparent nose position far outside the
/// calibrated band and then holds it rock-steady; a genuine slouch lives
/// near the band and wanders (people bob, breathe, and shift). So: when
/// readings stay far out of band with almost no wobble for a sustained
/// window, report the stable position so the caller can re-anchor to it.
///
/// Trade-off, accepted deliberately: someone who holds an extreme slouch
/// perfectly still for the whole window gets their position blessed as the
/// new baseline (they ignored the warning that whole time; further
/// slouching from there is still caught).
struct BaselineDriftMonitor {
    /// How long readings must stay far out of band before re-anchoring.
    /// Kept short: this is the slow backstop behind the instant
    /// camera-motion detector in CameraPostureDetector.
    var windowSeconds: TimeInterval = 12
    /// Maximum spread (max - min) across the window that still counts as
    /// "holding still". Generous enough for a person working normally in
    /// front of a moved camera, but a genuine slouch-and-recover arc
    /// travels further.
    var maxWobble: CGFloat = 0.06

    private var samples: [(time: Date, y: CGFloat)] = []

    /// Feed one reading. `isFarOutside` marks readings well beyond the
    /// calibrated band (in either direction); in-band readings reset the
    /// window. Returns the stable median position when drift is confirmed,
    /// at which point the monitor resets itself.
    mutating func ingest(y: CGFloat, at time: Date, isFarOutside: Bool) -> CGFloat? {
        guard isFarOutside else {
            samples.removeAll()
            return nil
        }

        samples.append((time, y))
        samples.removeAll { time.timeIntervalSince($0.time) > windowSeconds * 2 }

        guard let oldest = samples.first,
              time.timeIntervalSince(oldest.time) >= windowSeconds else { return nil }

        let ys = samples.map(\.y)
        guard let minY = ys.min(), let maxY = ys.max(), maxY - minY <= maxWobble else {
            // Too much movement to be a fixed camera; keep watching with a
            // fresh window so a later stable stretch can still qualify.
            samples.removeFirst(samples.count / 2)
            return nil
        }

        let sorted = ys.sorted()
        samples.removeAll()
        return sorted[sorted.count / 2]
    }

    mutating func reset() {
        samples.removeAll()
    }
}
