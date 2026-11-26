# Building Hoverbird

Hoverbird builds with **only Apple's Command Line Tools** — no Xcode project, no package manager. The
build script calls `swiftc` directly, compiles the vendored dependencies once and caches them, then
assembles and signs `Hoverbird.app`.

## Requirements

- macOS 14 or later on Apple silicon
- Command Line Tools: `xcode-select --install` (a full Xcode works too)
- A macOS SDK whose Swift interfaces your compiler can read — the script finds one for you
  (macOS 26 SDK recommended; Liquid Glass needs it)

## Build

```bash
git clone https://github.com/prashanth-manchikatla/Hoverbird.git
cd Hoverbird

./Scripts/build.sh             # → build/Hoverbird.app (optimized)
./Scripts/build.sh --debug     # unoptimized, faster to compile
./Scripts/build.sh --install   # build, move to /Applications, relaunch
```

The first build compiles the vendored modules (`Vendor/`) and takes a few minutes; later builds only
recompile the app. Warnings and errors go to `.build/manual/<config>/compile.log`.

`--install` *moves* the app to `/Applications` (so Spotlight and Launchpad only ever see one copy) and
restarts it. Plain builds stay in `build/`, which is kept out of Spotlight.

## Stable signing (recommended for development)

macOS ties privacy permissions — Accessibility, Screen Recording — to an app's code signature. Builds are
ad-hoc signed by default, so macOS may ask for those permissions again after every rebuild. Give your
builds a stable signature once:

```bash
./Scripts/setup-signing.sh             # macOS asks for your password once, to trust the certificate
./Scripts/setup-signing.sh --remove    # undo
```

This creates a private, self-signed identity named **Hoverbird Local Signing** in its own keychain
(`~/Library/Keychains/hoverbird-codesign.keychain-db`) with a random password in `.signing/`
(git-ignored). `build.sh` uses it automatically when present and falls back to ad-hoc signing otherwise.
The identity never leaves your Mac and is trusted only for code signing.

## Opening in Xcode

`Package.swift` mirrors the source layout, so you can open the folder in Xcode for code navigation and
previews. The canonical build — the one that produces a working app bundle with its resources and
frameworks — is `Scripts/build.sh`.

## Project layout

| Path | What's there |
|---|---|
| `boringNotch/` | The app. Upstream boring.notch code plus `boringNotch/Hoverbird/`, where everything Hoverbird adds lives, one folder per feature |
| `Vendor/` | Vendored Swift dependencies (see `Vendor/README.md`) |
| `mediaremote-adapter/` | The MediaRemote adapter that sends media commands (required since macOS 15.4) |
| `Resources/` | `Info.plist`, app icon, images |
| `Scripts/` | `build.sh`, `setup-signing.sh`, `make_icons.sh` (app icon from `Resources/Icon/AppIcon.svg`) |
| `docs/` | Documentation and README assets |

See [architecture.md](architecture.md) for how the pieces fit together.

## Runtime files

Hoverbird keeps a few files in `~/Library/Application Support/Hoverbird/`:

| File | Purpose |
|---|---|
| `notes.json` | Your to-dos and note (owner-only permissions) |
| `ai-pricing.json` | Extra or overriding model prices for AI Usage (optional) |
| `ai-debug.txt` | The *shape* of live-limit responses — keys and numbers only, never tokens |
| `tuning.json` | Live-video tuning knobs (`liveVideoDebug`, `liveVideoMotionThreshold`, …) |
| `liveactivity-rules.json` | Extra matching rules for mirrored iPhone Live Activities |
| `diagnostics.txt` | Written by *Settings › iPhone & Notifications › Export diagnostics* |

## Troubleshooting

<details>
<summary><b>“No usable macOS SDK found”</b></summary>

Your compiler can't read any installed SDK. Update the Command Line Tools
(`softwareupdate --list`), or point the script at an SDK: `SDKROOT=/path/to/MacOSX26.sdk ./Scripts/build.sh`.
</details>

<details>
<summary><b>macOS keeps asking for Accessibility / Screen Recording</b></summary>

Run `./Scripts/setup-signing.sh` once, rebuild, and grant the permissions one last time. If an entry is
stuck, remove Hoverbird from the list in *System Settings › Privacy & Security* and add it again.
</details>

<details>
<summary><b>`swift build` crashes</b></summary>

Some Command Line Tools releases ship a broken SwiftPM. That's why the build script uses `swiftc` directly
— use `./Scripts/build.sh`.
</details>
