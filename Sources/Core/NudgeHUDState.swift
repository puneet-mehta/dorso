import Foundation

/// What the nudge HUD label should show right now. Pure derivation from
/// warning intensities and the rest phase, mirroring PostureUIState.derive
/// so it stays headless-testable.
struct NudgeHUDState: Equatable {
    /// Text to display, or nil when the HUD is hidden.
    let text: String?

    /// Priority: rest countdown > posture > blink. The countdown is an
    /// explicit time-boxed ritual and shows even when no overlay warning is
    /// active (warning mode "none"); between the two warnings, the cause
    /// with the higher current intensity wins, tie-break posture.
    static func derive(
        postureIntensity: CGFloat,
        blinkIntensity: CGFloat,
        restPhase: RestPhase,
        now: Date,
        restDuration: TimeInterval
    ) -> NudgeHUDState {
        if case .resting(let startedAt) = restPhase {
            let remaining = max(0, restDuration - now.timeIntervalSince(startedAt))
            let seconds = Int(remaining.rounded(.up))
            let countdown = String(format: "0:%02d", seconds)
            return NudgeHUDState(text: L("nudge.rest.countdown", countdown))
        }
        if postureIntensity > 0, postureIntensity >= blinkIntensity {
            return NudgeHUDState(text: L("nudge.posture"))
        }
        if blinkIntensity > 0 {
            return NudgeHUDState(text: L("nudge.blink"))
        }
        return NudgeHUDState(text: nil)
    }
}
