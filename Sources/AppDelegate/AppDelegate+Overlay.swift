import AppKit
import CoreGraphics

extension AppDelegate {
    // MARK: - Overlay Windows

    func setupOverlayWindows() {
        for screen in NSScreen.screens {
            let frame = screen.overlayFrame(fullScreen: useFullScreenOverlay)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .aboveFullscreen
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            blurView.blendingMode = .behindWindow
            blurView.material = .fullScreenUI
            blurView.state = .active
            blurView.alphaValue = 0

            window.contentView = blurView
            window.orderFrontRegardless()
            windows.append(window)
            blurViews.append(blurView)
        }
    }

    /// Pushes the settings that warning overlay windows are built from into the
    /// manager. Every path that sets up or rebuilds the manager's windows must
    /// call this first so the manager never renders from stale settings.
    func syncWarningOverlaySettings() {
        warningOverlayManager.mode = activeWarningMode
        warningOverlayManager.warningColor = activeWarningColor
        warningOverlayManager.useFullScreenOverlay = useFullScreenOverlay
    }

    func rebuildOverlayWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        blurViews.removeAll()
        // New blur views start at alpha 0 and fresh window numbers carry no CGS
        // blur; reset the ramp so updateBlur repaints instead of skipping when
        // currentBlurRadius == targetBlurRadius.
        currentBlurRadius = 0
        withAccessoryActivationPolicy {
            setupOverlayWindows()

            if activeWarningMode.usesWarningOverlay {
                syncWarningOverlaySettings()
                warningOverlayManager.rebuildOverlayWindows()
            }
            nudgeLabelManager.rebuildWindows()
        }
    }

    func clearBlur() {
        targetBlurRadius = 0
        currentBlurRadius = 0

        for blurView in blurViews {
            blurView.alphaValue = 0
        }

        #if !APP_STORE
        if let getConnectionID = cgsMainConnectionID,
           let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
            let cid = getConnectionID()
            for window in windows {
                _ = setBlurRadius(cid, UInt32(window.windowNumber), 0)
            }
        }
        #endif
    }

    func switchWarningMode() {
        clearBlur()

        syncWarningOverlaySettings()

        warningOverlayManager.currentIntensity = 0
        warningOverlayManager.targetIntensity = 0
        for view in warningOverlayManager.overlayViews {
            if let glowView = view as? GlowOverlayView {
                glowView.intensity = 0
            } else if let borderView = view as? BorderOverlayView {
                borderView.intensity = 0
            }
        }

        for window in warningOverlayManager.windows {
            window.orderOut(nil)
        }
        warningOverlayManager.windows.removeAll()
        warningOverlayManager.overlayViews.removeAll()

        if activeWarningMode.usesWarningOverlay {
            withAccessoryActivationPolicy {
                warningOverlayManager.setupOverlayWindows()
            }
        }
    }

    func updateWarningColor(_ color: NSColor) {
        warningOverlayManager.updateColor(color)
    }

    // MARK: - Eye Care Nudge HUD

    /// Derive and render the nudge HUD label from current store state.
    func updateNudgeHUD() {
        let (restPhase, restDuration, blinkIntensity) = trackingStore.withState {
            ($0.eyeCareState.restPhase,
             $0.eyeCareConfig.restDurationSeconds,
             $0.eyeCareState.blinkNudgeIntensity)
        }
        let hud = NudgeHUDState.derive(
            postureIntensity: postureWarningIntensity,
            blinkIntensity: blinkIntensity,
            restPhase: restPhase,
            now: Date(),
            restDuration: restDuration
        )
        nudgeLabelManager.render(hud)
    }

    /// Dispatch `.eyeCareTick` from the 0.033s render timer at most once per
    /// wall-clock second while eye care is enabled and the app is active.
    func dispatchEyeCareTickIfDue() {
        guard eyeCareConfig.eyeCareEnabled, state.isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEyeCareTickTime) >= 1.0 else { return }
        lastEyeCareTickTime = now
        applyTrackingAction(.eyeCareTick(now: now, isMarketingMode: isMarketingMode))
    }

    func updateBlur() {
        let privacyBlurIntensity: CGFloat = isCurrentlyAway ? 1.0 : 0.0
        // Posture and blink nudges share the warning channel; the stronger
        // signal drives the visual, the HUD label names the cause.
        let warningIntensity = max(postureWarningIntensity, blinkNudgeIntensity)

        switch activeWarningMode {
        case .blur:
            let combinedIntensity = max(privacyBlurIntensity, warningIntensity)
            targetBlurRadius = Int32(combinedIntensity * 64)
            warningOverlayManager.targetIntensity = 0
        case .none:
            targetBlurRadius = Int32(privacyBlurIntensity * 64)
            warningOverlayManager.targetIntensity = 0
        case .glow, .border, .solid:
            targetBlurRadius = Int32(privacyBlurIntensity * 64)
            warningOverlayManager.targetIntensity = warningIntensity
        }

        // The cause label follows the warning signals on every tick (cheap:
        // the label manager no-ops while its text is unchanged). This is what
        // keeps posture-only warnings labeled too, and the rest countdown
        // ticking.
        updateNudgeHUD()

        // Skip work if nothing is changing
        let blurNeedsUpdate = currentBlurRadius != targetBlurRadius
        let overlayNeedsUpdate = warningOverlayManager.currentIntensity != warningOverlayManager.targetIntensity
        guard blurNeedsUpdate || overlayNeedsUpdate else { return }

        warningOverlayManager.updateWarning()

        if currentBlurRadius < targetBlurRadius {
            currentBlurRadius = min(currentBlurRadius + 1, targetBlurRadius)
        } else if currentBlurRadius > targetBlurRadius {
            currentBlurRadius = max(currentBlurRadius - 3, targetBlurRadius)
        }

        let normalizedBlur = CGFloat(currentBlurRadius) / 64.0
        let visualEffectAlpha = min(1.0, sqrt(normalizedBlur) * 1.2)

        #if APP_STORE
        for blurView in blurViews {
            blurView.alphaValue = visualEffectAlpha
        }
        #else
        if useCompatibilityMode {
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        } else if let getConnectionID = cgsMainConnectionID,
                  let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
            let cid = getConnectionID()
            for window in windows {
                _ = setBlurRadius(cid, UInt32(window.windowNumber), currentBlurRadius)
            }
        } else {
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        }
        #endif
    }
}
