# Dorso Eye Care preview

Preview build of the `feat/eye-care` branch — Dorso with eye-strain protection on top of the existing posture guarding. Updated automatically on every push to the branch.

## What's in it

- **Blink reminders** (camera mode) — notices when you stare at the screen without blinking and shows a gentle nudge using your configured warning style. Auto-calibrates to your eyes, glasses, and lighting; goes quiet instead of false-firing in poor conditions. Sensitivity is adjustable.
- **Cause-labeled nudges** — a small on-screen hint tells you *what* to fix: "Sit up straight", "Blink your eyes", or the rest countdown. Localized in English, German, Spanish, French, Japanese, and Simplified Chinese.
- **20-20-20 breaks** — after 20 minutes (configurable 10–40) of continuous screen time, a countdown prompts you to look 20 ft away for 20 seconds. Walking away counts as taking the break.
- **Analytics** — the dashboard now shows Eye Breaks and Blink Nudges alongside posture stats.
- Eye Care is **opt-in**: enable it in Settings after installing.
- This build has **no auto-updater and makes no network requests at all** — everything runs on your Mac.

## Install

1. Download `Dorso-eye-care-preview.zip` below and unzip it.
2. Drag `Dorso.app` to Applications.
3. **This preview is not notarized** (it's a community build without an Apple Developer certificate), so macOS will warn on first launch. Either right-click the app → **Open** → **Open**, or run:
   ```
   xattr -cr /Applications/Dorso.app
   ```
4. Launch, grant camera permission, calibrate, and enable **Eye Care** in Settings.

To try the 20-20-20 flow without waiting 20 minutes, launch with a shortened cycle (60 s interval, 10 s countdown):

```
open /Applications/Dorso.app --args --eye-care-debug
```

## Requirements

- macOS 13.0 (Ventura) or later
- A camera for posture + blink tracking (AirPods mode works for posture and rest reminders; blink detection is camera-only)

---

*Not an official Dorso release — this is a feature-branch preview from a fork of [tldev/dorso](https://github.com/tldev/dorso). For stable, signed builds see the [upstream releases](https://github.com/tldev/dorso/releases).*
