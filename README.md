# Darpan (दर्पण)

**Use your Android tablet as a wired second display for your Mac.**

*Darpan* means "mirror" in Nepali. It turns an Android tablet into a low-latency
extra display over a USB cable — no Wi-Fi, no accounts, no subscription.

- **Low latency** — hardware H.264 encode (VideoToolbox low-latency mode) to
  hardware decode (MediaCodec async, render-on-decode), 60fps, over USB via ADB
- **Full touch input** — tap, drag, two-finger scroll, long-press right-click,
  three/four-finger gestures for Spaces, Mission Control, and app switching,
  S Pen support
- **Retina-sharp** — streams at the tablet's native resolution with HiDPI 2x
- **Plug and play** — runs as a background service; connect the cable and the
  display appears

## Requirements

- **Mac**: Apple Silicon, macOS 14 (Sonoma) or later
- **Tablet**: Android 8.0+ with USB debugging enabled
- **adb** on the Mac: `brew install android-platform-tools`
- USB cable

## Install

### Mac host

```sh
git clone https://github.com/<you>/darpan.git
cd darpan
./scripts/install.sh
```

Grant the two permissions when prompted (System Settings → Privacy & Security):
**Screen Recording** and **Accessibility**. Both are required — one for
streaming the display, one for injecting mouse/keyboard input.

Alternatively, download `Darpan.dmg` from
[Releases](../../releases) and run its `install.sh`.

### Android app

Download `darpan.apk` from [Releases](../../releases) and install it on the
tablet (allow "install unknown apps" if asked), or build from source:

```sh
cd android-receiver && ./gradlew assembleRelease
```

Enable **USB debugging** on the tablet (Settings → About → tap *Build number*
7× → Developer options → USB debugging), connect the cable, accept the trust
prompt, and open the app.

## Gestures

| Input | Action |
|---|---|
| One finger | Mouse move / drag |
| Tap | Left click |
| Long-press | Right click |
| Two-finger drag | Scroll |
| Three-finger swipe left/right | Switch Spaces |
| Three-finger swipe down | Mission Control |
| Three-finger swipe up | Show Desktop |
| Three-finger tap | App Exposé |
| Four-finger swipe left/right | Cmd+Tab app switching |
| S Pen button + drag | Scroll |

## How it works

```
┌────────────── Mac ──────────────┐        ┌───────── Tablet ─────────┐
│ Virtual display (private        │  USB   │                          │
│ CGVirtualDisplay API)           │ (ADB   │                          │
│   → ScreenCaptureKit capture    │reverse)│  MediaCodec async decode │
│   → VideoToolbox H.264 encode ──┼────────┼─→ → SurfaceView render   │
│                                 │  TCP   │                          │
│ CGEvent input injection ←───────┼────────┼── touch / gestures       │
└─────────────────────────────────┘        └──────────────────────────┘
```

The host runs as a launchd agent, polls for a USB-connected device, sets up
`adb reverse` port forwarding, and streams a virtual display sized to the
tablet. Touch events flow back and are injected as mouse/keyboard events.

> **Note on private APIs**: the virtual display is created with Apple's
> private `CGVirtualDisplay` API (the same approach used by other virtual
> display projects). This works on current macOS versions but is not
> guaranteed by Apple, and it rules out Mac App Store distribution.

## Troubleshooting

- **Logs**: `tail -f ~/Library/Logs/SecondScreen/host.log`
- **Service status**: `launchctl list | grep secondscreen`
- **Black screen on tablet**: usually a missing Screen Recording permission —
  check the log for `TCC` errors
- **Touch not working**: missing Accessibility permission
- **Uninstall**: `./scripts/uninstall.sh`

## License

[MIT](LICENSE)
