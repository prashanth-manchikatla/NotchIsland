# Changelog

All notable changes to Hoverbird are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Hoverbird uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Wings:** the island opens like a bird spreading its wings — real feathers, coverts to primaries, with the
  lower body and tail — then the island's glass fills out from the bird until it becomes the island; closing
  folds it back into the notch. It's the new default; *Settings › Island › Motion* keeps the plain springs.
- **A bird all the way through:** the hummingbird hovers in empty sections (Home when nothing plays,
  Clipboard, Shelf, Notifications), a small flapping hummingbird replaces spinners while something works
  (an AI agent, syncing, loading, quitting apps), loose feathers drift as the island opens, and selected
  tabs, buttons and zones use the hummingbird's blue-to-violet plumage.
- **Cinema mode** for Netflix, Prime Video and other streaming services: quiet island and held
  notifications during full-screen video ("while you watched" summary), ±10 s / Skip intro / mute /
  full-screen controls with time left, the full-screen **Theater** that uses the whole 1.54:1 screen
  beside the notch, and VLC-style Fit / Fill / **Smart** / Stretch with zoom (Smart, the default, covers
  the screen with the smallest change; in the Theater, A changes the picture and a note says what it trims).
- Cinema shows the movie or episode's real title, key art and time left for Netflix (in its web app, a
  browser or the Theater) — Netflix itself tells macOS only "Netflix" and no time.
- **Windows › Arrange picks and orders your windows:** split the screen into 2–6 (new 4-, 5- and 6-window
  layouts), click the windows in the order you want them (zone 1, 2, 3…), and swap zones by dragging one onto
  another or clicking two. The island and the Expand panel share the same choice.

### Changed

- **Windows now lives inside the island:** Snap (12 layouts), Arrange and Apps open in the island instead of a
  separate panel. Only **Expand** opens the larger panel, on the same tab.
- **New app icon — Midnight Glass:** a glass hummingbird hovering at the island, glowing on deep midnight blue,
  on the macOS icon shape. The menu bar glyph is the same hummingbird. The icon's source is now an SVG
  (`Resources/Icon/AppIcon.svg`) built by `Scripts/make_icons.sh`.
- New README banner and social preview in the Midnight Glass style.

### Fixed

- `Scripts/setup-signing.sh` works with Homebrew's OpenSSL 4 (it now uses macOS's own `openssl`).
- Windows › Snap: pointing at a zone on the left or top of a layout lit up — and named — a different zone, while
  a click still snapped to the zone under the pointer. The highlight now always matches the zone you point at,
  in the island and in the Expand panel.
- Pressing play after a video is already full screen now quiets the island too.
- The connectivity button now shows Wi-Fi, hotspot, Ethernet, VPN and Bluetooth details inside the
  island instead of in a separate popover.
- Cinema: choosing Fit / Fill / Stretch while watching in the Netflix web app did nothing — the web app
  can't be resized by other apps, so the choice now moves the video into the Theater, where it applies.
- Cinema: after an update, the Theater asked for the Mac's login password again and again (WebKit kept an
  encryption key in the Keychain, tied to each build). The Theater now keeps its own key and never uses
  the Keychain.
- Lyrics are no longer looked up (by title, on lrclib.net) for movies and shows.
- AI Usage never repeats a Keychain read you denied or that timed out; only Refresh asks again.
- The island's top was cut off while a streaming service played: a portrait poster (Prime Video's) made
  the artwork, and with it the player, taller than the island. The artwork now keeps its usual size.
- Cinema: Fill, Smart and Stretch zoomed Prime Video's picture inside its 16:9 frame instead of filling the
  screen. Players that clip their video to a frame are now handled (and restored for Fit).
- Cinema: "Full 1.54:1" from the Prime Video app opened Prime Video's home page; it now opens the same title
  and resumes at the same moment.
- Cinema: the Theater could not be left — Esc counted Prime Video's sliders as typing, and when macOS gave
  the keyboard to another app the Theater still covered the screen. Esc now always leaves (from anywhere),
  and a Leave Theater button appears in the top-left corner.
- Cinema: the Theater asked to sign in again after every restart (Amazon / Prime Video India signs in with
  cookies that end at quit) and showed Netflix's "Who's watching?" — sign-ins are now kept and your Netflix
  profile is picked for you.
- Cinema: moving Netflix into the Theater started paused, at Netflix's own bookmark; it now continues at
  the same second, playing. The Theater no longer opens in Fit (its picture is the same as normal full
  screen), and picture modes no longer resize the trailer in a page's header.

## [1.0.0-beta.1] — 2026-11-25

The first public beta. Hoverbird grows out of [boring.notch](https://github.com/TheBoredTeam/boring.notch)
into an iPhone-style Dynamic Island for the MacBook notch.

### Added

- **The island:** black glass with adjustable tint, optional macOS 26 Liquid Glass, glass rim and
  iPhone-style springs; proximity growth, instant open at the top edge, two-finger swipes and pinning.
- **Live Activities:** one primary activity around the camera and a detached bubble, with a single
  priority order for recordings, timers, banners, meetings, orders, media and more.
- **AI Usage:** limits, tokens, tasks, sessions, running agents and alerts for Claude Code, Codex,
  Gemini CLI and Grok CLI, plus OpenRouter, OpenAI and DeepSeek API accounts; opt-in live limits; an AI
  Usage window with charts and CSV export.
- **Focus:** Pomodoro sessions with breaks, streaks, generated focus sounds and 20-20-20 reminders.
- **Notes:** to-dos and a quick note in the island, with a non-activating panel for typing.
- **Camera:** photos, video with sound and real full screen; always starts with the Mac's camera, with a
  one-click switch to a nearby iPhone (Continuity Camera).
- **Capture:** screenshots, ScreenCaptureKit recording, Copy Text (on-device OCR, ⇧⌘2), Scan QR and Pick
  Color.
- **Clipboard:** history with pinning and filters, clean links, paste as plain text (⌃⌥V).
- **Notifications & iPhone:** mirrored banners with a reader (open, copy one-time codes, mark read,
  clear), order and ride tracking, mirrored iPhone Live Activities, Shortcuts on the iPhone.
- **Meetings:** system-wide microphone mute (⌃⌥M) with a "Muted" indicator, camera-in-use alerts,
  one-click Join.
- **Windows:** snap layouts, a live arrange mini-map, quit and force-quit apps.
- **Devices & files:** accessory batteries (AirPods per bud), connectivity, battery alerts, download
  and drive islands.
- **Monitor:** CPU per cluster, GPU, memory, power and temperatures without admin rights.
- **Media:** the playing video inside the artwork, DRM-aware fallbacks and reliable YouTube controls.
- Tabs can be hidden, and tab buttons size themselves to the space beside the notch.
- Builds with only the Command Line Tools (`Scripts/build.sh`), with optional stable signing
  (`Scripts/setup-signing.sh`).

### Changed

- Media commands go through the bundled MediaRemote adapter (required since macOS 15.4).
- The open island is wider to fit more tabs.

### Fixed

- The media helper process no longer lingers after Hoverbird quits.
- The island no longer stays open when a stale popover or automation state blocked it from closing.

### Removed

- boring.notch's Sparkle updater, XPC helper and Xcode project (Hoverbird builds with `Scripts/build.sh`).

[Unreleased]: https://github.com/prashanth-manchikatla/Hoverbird/compare/v1.0.0-beta.1...HEAD
[1.0.0-beta.1]: https://github.com/prashanth-manchikatla/Hoverbird/releases/tag/v1.0.0-beta.1
