import AppKit

/// Small non-activating HUD capsule shown top-center on every screen with a
/// short hint of what to fix ("Sit up straight", "Blink your eyes", the
/// 20-20-20 countdown). Public APIs only — safe for App Store builds.
@MainActor
final class NudgeLabelManager {
    private var panels: [NSPanel] = []
    private var labels: [NSTextField] = []
    private var currentText: String?

    /// Create one panel per screen. Must be called inside
    /// `withAccessoryActivationPolicy` per the recipe at
    /// `NSWindow.Level.aboveFullscreen`.
    func setupWindows() {
        for screen in NSScreen.screens {
            let panelWidth: CGFloat = 320
            let panelHeight: CGFloat = 44
            let frame = NSRect(
                x: screen.frame.midX - panelWidth / 2,
                y: screen.frame.maxY - panelHeight - 48,
                width: panelWidth,
                height: panelHeight
            )

            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .aboveFullscreen
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.alphaValue = 0

            let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            effectView.material = .hudWindow
            effectView.state = .active
            effectView.blendingMode = .behindWindow
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = panelHeight / 2
            effectView.layer?.masksToBounds = true
            effectView.layer?.borderWidth = 1
            effectView.layer?.borderColor = NSColor(
                red: 0.31, green: 0.82, blue: 0.77, alpha: 0.3  // brandCyan
            ).cgColor

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textColor = .labelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 16, y: 0, width: frame.width - 32, height: frame.height)
            label.autoresizingMask = [.width, .height]
            // Center the single line vertically.
            let labelHeight = label.font?.pointSize.rounded(.up) ?? 15
            label.frame = NSRect(
                x: 16,
                y: (frame.height - labelHeight - 6) / 2,
                width: frame.width - 32,
                height: labelHeight + 6
            )
            effectView.addSubview(label)

            panel.contentView = effectView
            panel.orderFrontRegardless()

            panels.append(panel)
            labels.append(label)
        }
    }

    /// Tear down and recreate windows (display configuration changed).
    /// Must be called inside `withAccessoryActivationPolicy`.
    func rebuildWindows() {
        let text = currentText
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        labels.removeAll()
        currentText = nil
        setupWindows()
        if let text {
            render(NudgeHUDState(text: text))
        }
    }

    /// Show/update/hide the label. No-ops when the text is unchanged so it
    /// can safely run on every render tick.
    func render(_ hud: NudgeHUDState) {
        guard hud.text != currentText else { return }
        let wasVisible = currentText != nil
        currentText = hud.text

        if let text = hud.text {
            for label in labels {
                label.stringValue = text
            }
            if !wasVisible {
                for panel in panels {
                    panel.orderFrontRegardless()
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        panel.animator().alphaValue = 1
                    }
                }
            }
        } else {
            for panel in panels {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak panel] in
                    panel?.orderOut(nil)
                })
            }
        }
    }

    func hide() {
        render(NudgeHUDState(text: nil))
    }
}
