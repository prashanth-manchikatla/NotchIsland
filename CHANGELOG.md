# Changelog

All notable changes to Hoverbird are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Hoverbird uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
