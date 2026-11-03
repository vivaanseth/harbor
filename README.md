# Intel Docktor

A native rebuild of [docktor](https://docktorapp.com/) for Macs that can't run macOS 26.
Targets **macOS 14 Sonoma+**, built natively for **Intel (x86_64)**, with optional Universal builds.

- **Dock previews**: hover an app in the Dock to see live thumbnails of its windows, including minimized windows and windows on other Spaces. Click one to jump to it. Hover a card to close or minimize that window.
- **Cmd+Tab switcher**: shows the highlighted app's windows as thumbnails. Press ↑ to move into the window row, ←/→ to pick a window, and release ⌘ to switch. Q quits the app, H hides it, W closes the selected window, and Esc cancels.
- **Glass widgets beside the Dock** (click any one to open its drawer):
  - **Music**: Apple Music and Spotify. Includes Up Next, Playlists, synced Lyrics (LRCLIB), Recent, and library search.
  - **Calendar**: Apple Calendar via EventKit. Shows the next event with a countdown, a join-meeting button, Remind 5m, and today's schedule.
  - **Weather**: Open-Meteo. Has Now, Hourly and 7-day pages, plus saved locations.
  - **System Stats**: CPU, RAM, SSD, GPU, disk I/O and network, with sparklines, top processes, process search and a large-file finder.
  - **Device Batteries**: your Mac's battery, Magic Mouse, Keyboard and Trackpad, and AirPods (L / R / Case).
  - **Smart Stack** (off by default): one slot holding several widgets. Scroll over it to flip; it turns to a running timer, an upcoming event or playing music on its own. Choose what it holds in Settings → Widgets.
  - **Focus Timer** (off by default): a Pomodoro ring with focus and break lengths. It keeps counting through sleep and relaunch.
- **Customize** in Settings → Widgets: which widgets show, the side, order, layout (Glance, Full or Automatic), size (Small, Medium or Large), widget height, and how drawers open (hover, click or never). Widgets that don't fit move to the other side of the Dock.
- **Music from any app**: in Automatic mode, the Music widget also shows and controls what Safari, Chrome and other apps are playing.
- **Window tiling** (off by default): ⌃⌥← / ⌃⌥→ snap the front window to a half, then a third, then a fourth. ⌃⌥↑ fills the screen and ⌃⌥↓ centers the window.

## Build

```bash
./build.sh                # Intel release build → build/Intel Docktor.app
UNIVERSAL=1 ./build.sh    # Intel + Apple silicon
./build.sh --install      # also copies the app to /Applications
CONFIG=debug ./build.sh   # quick iteration build
```

Requires Xcode 15+ (or Xcode Command Line Tools with Swift 5.9+).

## Permissions

Nothing is requested at launch. Grant each one from **Settings → Permissions** when you want the feature that needs it:

| Permission | Used for |
| --- | --- |
| Accessibility | Dock previews, Cmd+Tab switcher, focusing windows, exact Dock measurement |
| Screen Recording | Window thumbnails (ScreenCaptureKit) |
| Calendar | Calendar widget |
| Location | Weather for your current location (otherwise your time zone's city or a saved city) |
| Automation | Controlling Apple Music / Spotify |
| Notifications | Calendar reminders |

Builds are signed with a local self-signed identity ("Intel Docktor Local Signing", created by `scripts/setup-signing.sh` and stored in `.signing/`), so macOS recognizes each rebuild as the same app and keeps its permissions. `.signing/` holds a private key: keep it to yourself. Without it, `build.sh` falls back to ad-hoc signing, and permissions then have to be granted again after every rebuild.

## Notes

- Widgets fill the space on either side of the Dock and fall back to compact "glance" tiles when there isn't room. A smaller Dock (System Settings → Desktop & Dock → Size) leaves room for the full-width layouts.
- Widgets only appear when the Dock is at the bottom of the screen. They follow Dock magnification and auto-hide, and stay off full-screen Spaces.
- The Cmd+Tab switcher turns off macOS's built-in one only while Intel Docktor is running. Quitting or crashing restores the built-in switcher.
