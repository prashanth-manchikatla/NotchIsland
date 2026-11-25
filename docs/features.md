# Feature tour

Everything Hoverbird does, area by area. Most features have a page in **Settings** where they can be
tuned or switched off.

- [The island](#the-island) · [Live Activities](#live-activities) · [Media](#media) · [AI Usage](#ai-usage)
- [Focus, timers & stopwatches](#focus-timers--stopwatches) · [Notes](#notes) · [Camera](#camera)
- [Capture & screen tools](#capture--screen-tools) · [Clipboard](#clipboard) · [Notifications & iPhone](#notifications--iphone)
- [Meetings, microphone & camera](#meetings-microphone--camera) · [Windows](#windows) · [Devices & files](#devices--files)
- [Monitor](#monitor) · [Awake](#awake) · [Calendar & weather](#calendar--weather)

---

## The island

- **Black glass** with an adjustable tint, optional macOS 26 **Liquid Glass**, a subtle glass rim and
  iPhone-style springs. The compact pill stays solid black so it melts into the camera housing.
- **Opening:** hover the notch, flick the pointer to the top edge for an instant open, or swipe down
  with two fingers (up to close). The pill grows slightly as the pointer approaches. **Pin** keeps it open.
- **Header:** Windows · Pin · Lock · Awake · Calendar · Camera · Connectivity.
- **Tabs:** Home · Shelf · Clipboard · Capture · Notifications · Timer · Notes · AI Usage · Shortcuts ·
  Monitor. Tab buttons share the space beside the notch; hide the ones you don't use in
  *Settings › Island › Tabs*.
- Can hide itself from screenshots and screen sharing (*Settings › Island*).

## Live Activities

One primary activity wraps the camera; a second floats as a detached bubble, iPhone-style. Priority:
recording → timer done → banners and pills → microphone muted → an AI agent that needs you → timers →
focus → iPhone orders → iPhone Live Activities → next meeting → stopwatches → working AI agents → music
→ Awake.

## Media

- **Now Playing** for every app — Music, Spotify, browsers, web apps, video players — through the bundled
  MediaRemote adapter (needed since macOS 15.4). Lyrics and a visualizer.
- **Live video:** while a video plays, the artwork becomes the video itself. The player is found through
  Accessibility, with motion detection as a fallback. Streaming services that use DRM (Netflix, Prime
  Video, Apple TV, Disney+ and others) and learning platforms show the artwork and episode details instead.
- **Not Playing:** when nothing plays, Home shows a clean card (with Resume when a paused player remains).
- YouTube controls work in the background and from other desktops.

## AI Usage

A live view of how much AI you use, read from the logs your tools already keep on your Mac.

| Source | What Hoverbird reads |
|---|---|
| **Claude Code** (terminal, VS Code, JetBrains, Claude Desktop) | `~/.claude/projects` transcripts; running sessions from `~/.claude/sessions` |
| **Codex** (ChatGPT plan) | `~/.codex/sessions` rollouts, including the plan's rate-limit windows |
| **Gemini CLI** | `~/.gemini/tmp/*/chats` recordings |
| **Grok CLI** | `~/.grok/sessions` usage summaries |
| **API accounts** | OpenRouter (credits, spend), OpenAI (organization admin key: spend, tokens), DeepSeek (balance) |

- **Limits:** the 5-hour and weekly windows with reset times and a *pace marker* (where you'd be at an even
  pace). Without live limits, the current 5-hour window is estimated from your activity.
- **Live limits (opt-in):** the exact numbers Claude Code shows in `/usage` — read with Claude Code's own
  sign-in (macOS asks once for Keychain access). Codex and Grok CLI work the same way with their sign-ins.
- **Agents:** every running session — *Working*, *Idle* or **Needs you** (waiting for a permission or an
  answer) — with what it's doing, its subagents, its tokens, and a button to bring its app forward.
- **Tasks:** every prompt you gave an agent, with how long it ran, its tokens and approximate cost
  (subagent calls are credited to the prompt that started them).
- **Sessions:** a time log with active time, tasks, tokens and cost. **Models**, **Projects** and a **Log**
  of every call. Everything exports to CSV.
- **Closed island:** an agent that needs you takes over; a working agent shows its timer; 📌 keeps the
  tightest limit's percentage visible.
- **Alerts:** 50 / 80 / 95 % of a limit, "runs out at this pace", limit reached, limit reset, and
  "finished" when an agent stops after working a while.
- **Costs** are estimates at public API prices (on a flat plan you don't pay them). Prices can be
  overridden in `ai-pricing.json`. Claude calls are deduplicated by message and request id, because Claude
  Code writes one row per content block.

## Focus, timers & stopwatches

- **Timers and stopwatches:** run as many as you like. One gets the big ring, several become rows. The
  closed island shows the next to finish with a "+N" count.
- **Focus:** Pomodoro sessions — focus, short break, long break every N sessions — with auto-start options,
  a chime, today's focus minutes, a day streak and a 7-day chart. The closed island shows a ring and the
  time left.
- **Focus sounds:** brown, pink and white noise and ocean swells, generated on the Mac.
- **Eye breaks:** optional 20-20-20 reminders, skipped while you're away from the Mac.

## Notes

- A to-do list and a quick note in the island. Tick to-dos off right there; ＋ and ✎ open a small glass
  panel under the notch for typing.
- The island itself never takes the keyboard, so it can't steal focus from your app. Esc or a click
  elsewhere closes the panel.
- Ticked to-dos clear themselves after a day. Stored only on your Mac.

## Camera

- A mirror on every tab. Hover it to **record** a video (with sound — the mic is on only while recording),
  take a full-resolution **photo**, or go **full screen** (real macOS full screen, with a self-timer,
  mirroring, fit / fill and keyboard shortcuts).
- Always starts with your **Mac's camera**. When an iPhone is nearby (Continuity Camera), a switch on the
  mirror moves the picture to the iPhone — tagged with its name — until the camera turns off. If the iPhone
  leaves, the mirror falls back to the Mac's camera.

## Capture & screen tools

- **Screenshots** of a selection, a window or the full screen (the system `screencapture`).
- **Screen recording** of a selection or the full screen with ScreenCaptureKit (HEVC), optional system
  audio and microphone, click highlights and a 3-2-1 countdown.
- **Copy Text** (⇧⌘2): drag over anything on screen — a video, an image, an error dialog — and its text is
  copied, using Apple's on-device Vision.
- **Scan QR:** QR codes and barcodes. **Pick Color:** the system loupe, copied as hex.
- Results go to the clipboard, the Shelf, or both.

## Clipboard

- History of text, links, colours, images and files, with pinning and filters. ⌘C ⌘C or ⌃⌥C opens it.
- Password managers and concealed items are skipped.
- **Clean links:** tracking parameters (`utm_*`, `fbclid`, `gclid`, YouTube / Spotify `si`, X `s`/`t`…)
  are removed when you copy a link.
- **Paste as plain text** (⌃⌥V) in any app, restoring your rich clipboard afterwards.

## Notifications & iPhone

- Mirrors notification banners — including those your iPhone forwards — into the island and a
  Notifications tab that stays in sync with Notification Center.
- Read a notification in full, open it, mark it read, copy it or its one-time code, open its link, clear
  it or mute its app.
- Order, delivery and ride updates become a persistent activity with the stage and a live ETA.
- iPhone Live Activities that macOS shows in the menu bar are mirrored too.
- iPhone-only Shortcuts can run on the iPhone through iPhone Mirroring.

## Meetings, microphone & camera

- **Mute the microphone** for every app at once with ⌃⌥M or the menu bar. A red **Muted** shows in the
  closed island while an app uses the muted mic, and it stays muted if you switch microphones.
- A pill when another app turns on a camera (and optionally the microphone).
- **Upcoming meetings** with a one-click Join for Zoom, Meet, Teams, Webex and FaceTime.

## Windows

- **Snap** the front window into halves, thirds, quarters and more (⌃⌥ shortcuts), with a frosted preview.
- **Arrange:** a live mini-map of your windows; drag them between zones.
- **Apps:** every open app with quit, plus Quit All and Force Quit.

## Devices & files

- **Batteries:** this Mac and every connected accessory, Apple-widget style — AirPods left / right / case,
  with charging state and low-battery warnings. Optional alerts when this Mac is charged to your level or
  running low.
- **Connectivity:** Wi-Fi, Personal Hotspot, Ethernet and Bluetooth at a glance.
- **Downloads:** a finished download shows in the island and lands on the Shelf.
- **Drives:** a pill when a drive connects; eject it from the menu bar.
- **Shelf:** drop files on the notch to keep them handy; AirDrop and share from there.

## Monitor

Live CPU (performance and efficiency clusters, frequency, temperature), GPU, memory pressure, power and
I/O — read with no admin rights. A detailed window has per-core load, every temperature sensor, power per
component, disk and network graphs and a process table.

## Awake

Keep the Mac awake for a while, until a time, or indefinitely — optionally with the display on, or with
the lid closed (asks for your administrator password and restores itself automatically).

## Calendar & weather

Your agenda, the time, and the local weather; an activity before your next meeting.
