# Architecture

A short map of how Hoverbird is put together, for contributors.

## Principles

1. **Event-driven, never polling.** Features react to the system: FSEvents for files, IOKit power-source
   callbacks for batteries, CoreAudio / CoreMediaIO property listeners for the microphone and cameras,
   Darwin and workspace notifications, `NWPathMonitor` for the network. Work that must sample (the
   system monitor, live video) runs only while its view is on screen.
2. **Small and quiet.** Idle CPU stays near 0 % and memory small. Measure with `footprint` and
   Activity Monitor before and after a change that touches a hot path.
3. **Private by default.** Nothing leaves the Mac unless the feature is the thing you asked for, and
   anything that reads another app's data or sign-in is opt-in. See [privacy.md](privacy.md).
4. **The island never steals focus.** Its window can't become key. Anything that needs typing opens a
   separate, non-activating panel.
5. **One feature, one folder.** New work lives in `boringNotch/Hoverbird/<Feature>/` with a header
   comment explaining what it does and why.

## The pieces

```
boringNotch/
├── ContentView.swift            the island: open / closed layout, tab routing
├── boringNotchApp.swift         app delegate, one island window per screen
└── Hoverbird/
    ├── HoverbirdBootstrap.swift   starts every service at launch, registers shortcuts
    ├── IslandActivityHub.swift      decides what the closed island shows (priority + bubble)
    ├── IslandSettings.swift         preference keys (Defaults)
    ├── AI/                          AI Usage
    │   ├── Core/        models · pricing · DB · aggregator · engine (background queue) · store (@MainActor) · alerts
    │   ├── Providers/   Claude logs + running agents · Codex · Gemini · Grok · live limits · API accounts
    │   └── Views/       tab · closed-island views · window · settings
    ├── Camera/ Capture/ Clipboard/ Focus/ Meeting/ Notes/ Tools/ Files/ Devices/ ...
    ├── Shared/FSEventsWatcher.swift
    └── Views/                       shared views, settings pages, compact (closed-island) views
```

### The island and its activities

`ContentView` renders each screen's island. When open, the header shows tabs (`TabSelectionView`) and
header buttons, and the body switches on `NotchViews`. When closed, `IslandActivityHub` picks one
**primary** activity (it wraps the camera) and an optional **secondary** bubble from everything that is
live. Its priority list — recording, timers, banners, an AI agent that needs you, focus, orders,
meetings… — is the single source of truth. To add an activity: add a case to `IslandCompactActivity`, a
publisher to the hub's sources, a line in `recompute()`, and views in `IslandCompactViews.swift`.

Short messages ("Copied", "Microphone muted") are **pills**: `IslandActivityHub.shared.showPill(…)`.

### AI Usage

```
FSEvents ──► AIUsageEngine (serial utility queue)
               ├─ ingestors read only the bytes appended since last time (AIFileReader)
               ├─ AIUsageDB: deduplicated calls, tasks, sessions, limit events, activity
               └─ AIUsageAggregator ──► AIUsageSnapshot ──► AIUsageStore (@MainActor) ──► views, alerts
                                                       ▲
               AILiveLimits / AIAPIAccounts (opt-in) ──┘
```

- Each provider implements `AILogIngestor` (`roots`, `owns`, `files(modifiedSince:)`, `ingest`).
- The full rollup is rebuilt only while the tab or window is visible; otherwise only the agents list is
  refreshed, which is what the closed island needs.
- Claude Code writes one row per content block, so calls are keyed by `message.id` + `requestId`.
- Running Claude sessions come from `~/.claude/sessions/<pid>.json` (`busy` / `idle` / `waiting`).

### Dependencies

Swift packages are vendored in `Vendor/` and compiled by `Scripts/build.sh` — no network at build time.
Keep new dependencies to a minimum; prefer system frameworks.
