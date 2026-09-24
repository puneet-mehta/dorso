import Foundation

// MARK: - Configuration

/// User-facing movement break configuration (app-level settings).
struct MovementConfig: Equatable {
    var movementReminderEnabled: Bool = false
    /// Continuous sitting time before a stand-up prompt (default 45 min).
    var sittingIntervalSeconds: TimeInterval = 45 * 60

    // Tuning (not user-facing)
    /// Being away from the camera at least this long counts as a real
    /// movement break; shorter absences merely pause the accumulator
    /// (leaning out of frame is not a walk).
    var breakAwaySeconds: TimeInterval = 60
    /// How long the stand-up prompt stays on screen before giving up and
    /// resetting the cycle.
    var promptMaxDuration: TimeInterval = 3 * 60
}

// MARK: - State

/// Phase of the movement break cycle.
enum MovementPhase: Equatable {
    case idle
    case prompting(startedAt: Date)
}

/// Pure state for movement monitoring - no side effects, fully testable.
struct MovementState: Equatable {
    /// Continuous seconds sitting at the screen (presence = sitting).
    var sittingSeconds: TimeInterval = 0
    /// Consecutive seconds currently away from the camera.
    var awaySeconds: TimeInterval = 0
    var phase: MovementPhase = .idle

    mutating func reset() {
        sittingSeconds = 0
        awaySeconds = 0
        phase = .idle
    }
}

// MARK: - Effects

/// Side effects the engine requests but doesn't execute.
enum MovementEffect: Equatable {
    case updateNudgeHUD
    case recordMovementBreak
}

/// Result of processing a movement tick.
struct MovementTransitionResult: Equatable {
    let newState: MovementState
    let effects: [MovementEffect]
}

// MARK: - Engine

/// Pure state-transition functions for stand-up/movement breaks, mirroring
/// EyeCareEngine. Driven by the shared 1 Hz wellness tick; "sitting" is
/// approximated by presence at the screen while monitoring.
enum MovementEngine {

    static func processTick(
        now: Date,
        state: MovementState,
        config: MovementConfig,
        appState: AppState,
        isAway: Bool
    ) -> MovementTransitionResult {
        var newState = state
        var effects: [MovementEffect] = []

        guard config.movementReminderEnabled, appState == .monitoring else {
            if newState != MovementState() {
                let wasPrompting = newState.phase != .idle
                newState.reset()
                if wasPrompting { effects.append(.updateNudgeHUD) }
            }
            return MovementTransitionResult(newState: newState, effects: effects)
        }

        if isAway {
            newState.awaySeconds += 1
            // A sustained absence is a real break: complete any prompt and
            // restart the sitting clock.
            if newState.awaySeconds >= config.breakAwaySeconds {
                let wasPrompting = newState.phase != .idle
                if wasPrompting {
                    effects.append(.recordMovementBreak)
                    effects.append(.updateNudgeHUD)
                    newState.phase = .idle
                }
                newState.sittingSeconds = 0
                // Keep counting away time so the state stays truthful, but
                // the cycle is already reset.
            }
            return MovementTransitionResult(newState: newState, effects: effects)
        }

        // Present at the screen.
        newState.awaySeconds = 0

        switch newState.phase {
        case .idle:
            newState.sittingSeconds += 1
            if newState.sittingSeconds >= config.sittingIntervalSeconds {
                newState.phase = .prompting(startedAt: now)
                effects.append(.updateNudgeHUD)
            }
        case .prompting(let startedAt):
            // Still sitting through the prompt; give up after a while so it
            // doesn't nag forever, and restart the cycle.
            if now.timeIntervalSince(startedAt) >= config.promptMaxDuration {
                newState.phase = .idle
                newState.sittingSeconds = 0
                effects.append(.updateNudgeHUD)
            }
        }

        return MovementTransitionResult(newState: newState, effects: effects)
    }
}
