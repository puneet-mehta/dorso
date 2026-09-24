import Foundation

/// What the nudge HUD label should show right now. Pure derivation from
/// warning intensities and the rest phase, mirroring PostureUIState.derive
/// so it stays headless-testable.
struct NudgeHUDState: Equatable {
    /// Text to display, or nil when the HUD is hidden.
    let text: String?

    /// Minimum warning intensity before the label appears. The label must
    /// never be stricter than the visual: the intensity-shaping curve
    /// deliberately crushes marginal severities to near-zero (invisible
    /// blur), and those must not surface as an accusatory text label.
    /// 0.15 is roughly where blur (radius ~10) becomes perceptible.
    static let labelThreshold: CGFloat = 0.15

    /// Priority: rest countdown > posture > blink > movement > smile. The countdown
    /// is an explicit time-boxed ritual and shows even when no overlay
    /// warning is active (warning mode "none"); between the two warnings,
    /// the cause with the higher current intensity wins, tie-break posture.
    /// The stand-up prompt is ambient and yields to anything actionable-now.
    static func derive(
        postureIntensity: CGFloat,
        postureCause: PostureWarningCause = .slouch,
        blinkIntensity: CGFloat,
        restPhase: RestPhase,
        movementPhase: MovementPhase = .idle,
        smilePhase: SmilePhase = .idle,
        now: Date,
        restDuration: TimeInterval
    ) -> NudgeHUDState {
        if case .resting(let startedAt) = restPhase {
            let remaining = max(0, restDuration - now.timeIntervalSince(startedAt))
            let seconds = Int(remaining.rounded(.up))
            let countdown = String(format: "0:%02d", seconds)
            return NudgeHUDState(text: L("nudge.rest.countdown", countdown))
        }
        if postureIntensity >= labelThreshold, postureIntensity >= blinkIntensity {
            let key = postureCause == .forwardHead ? "nudge.forwardHead" : "nudge.posture"
            return NudgeHUDState(text: L(key))
        }
        if blinkIntensity >= labelThreshold {
            return NudgeHUDState(text: L("nudge.blink"))
        }
        if case .prompting = movementPhase {
            return NudgeHUDState(text: L("nudge.movement"))
        }
        if case .prompting = smilePhase {
            return NudgeHUDState(text: L("nudge.smile"))
        }
        return NudgeHUDState(text: nil)
    }
}
