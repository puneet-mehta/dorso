import Foundation

// MARK: - Configuration

/// User-facing smile reminder configuration (app-level settings).
struct SmileConfig: Equatable {
    var smileReminderEnabled: Bool = false
    /// How long without a smile before the reminder appears (default 15 min).
    var smileIntervalSeconds: TimeInterval = 15 * 60

    // Tuning (not user-facing)
    /// How long the reminder stays on screen before quietly restarting the
    /// cycle.
    var promptMaxDuration: TimeInterval = 15
}

// MARK: - State

/// Phase of the smile reminder cycle.
enum SmilePhase: Equatable {
    case idle
    case prompting(startedAt: Date)
}

/// Pure state for smile monitoring - no side effects, fully testable.
struct SmileState: Equatable {
    /// Seconds of screen presence since the last confirmed smile.
    var secondsSinceSmile: TimeInterval = 0
    var phase: SmilePhase = .idle

    mutating func reset() {
        secondsSinceSmile = 0
        phase = .idle
    }
}

// MARK: - Effects

/// Side effects the engine requests but doesn't execute.
enum SmileEffect: Equatable {
    case updateNudgeHUD
    case recordSmile
}

/// Result of processing a smile input.
struct SmileTransitionResult: Equatable {
    let newState: SmileState
    let effects: [SmileEffect]
}

// MARK: - Engine

/// Pure state-transition functions for smile reminders, mirroring
/// MovementEngine. Smiles arrive via the camera's 1 Hz activity samples;
/// the shared wellness tick advances the no-smile timer.
enum SmileEngine {

    /// Process the smile portion of a 1 Hz camera activity sample.
    static func processActivity(
        _ sample: BlinkActivitySample,
        state: SmileState,
        config: SmileConfig
    ) -> SmileTransitionResult {
        guard config.smileReminderEnabled, sample.smileCount > 0 else {
            return SmileTransitionResult(newState: state, effects: [])
        }

        var newState = state
        var effects: [SmileEffect] = Array(repeating: .recordSmile, count: sample.smileCount)
        newState.secondsSinceSmile = 0
        if newState.phase != .idle {
            newState.phase = .idle
            effects.append(.updateNudgeHUD)
        }
        return SmileTransitionResult(newState: newState, effects: effects)
    }

    /// Process a 1 Hz wall-clock tick.
    static func processTick(
        now: Date,
        state: SmileState,
        config: SmileConfig,
        appState: AppState,
        isAway: Bool
    ) -> SmileTransitionResult {
        var newState = state
        var effects: [SmileEffect] = []

        guard config.smileReminderEnabled, appState == .monitoring else {
            if newState != SmileState() {
                let wasPrompting = newState.phase != .idle
                newState.reset()
                if wasPrompting { effects.append(.updateNudgeHUD) }
            }
            return SmileTransitionResult(newState: newState, effects: effects)
        }

        // Nobody to remind while away; the timer simply pauses.
        guard !isAway else {
            return SmileTransitionResult(newState: newState, effects: effects)
        }

        switch newState.phase {
        case .idle:
            newState.secondsSinceSmile += 1
            if newState.secondsSinceSmile >= config.smileIntervalSeconds {
                newState.phase = .prompting(startedAt: now)
                effects.append(.updateNudgeHUD)
            }
        case .prompting(let startedAt):
            // Gentle by design: after a short while the reminder bows out
            // and the cycle restarts.
            if now.timeIntervalSince(startedAt) >= config.promptMaxDuration {
                newState.phase = .idle
                newState.secondsSinceSmile = 0
                effects.append(.updateNudgeHUD)
            }
        }

        return SmileTransitionResult(newState: newState, effects: effects)
    }
}
