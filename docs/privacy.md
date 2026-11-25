# Privacy

NotchIsland has **no accounts, no analytics and no telemetry**. It doesn't phone home, and it has no
server of its own. Everything below runs on your Mac; the few features that talk to the internet say so,
and each one is either essential to what you asked for or switched off until you turn it on.

## What stays on your Mac

| Feature | What it reads | Where results are kept |
|---|---|---|
| AI Usage | Logs your AI tools already write: `~/.claude`, `~/.codex`, `~/.gemini`, `~/.grok` | In memory only. Prompt text is shown in the app but never written anywhere by NotchIsland |
| Notes | — | `~/Library/Application Support/NotchIsland/notes.json` (owner-only) |
| Clipboard history | The clipboard (skipping password managers and concealed items) | Application Support, on this Mac |
| Notifications | Notification banners, through Accessibility | In memory |
| Copy Text / Scan QR | The area of the screen you select, read with Apple's on-device Vision | The clipboard |
| Focus | — | Daily focus minutes in preferences |
| Camera & screen capture | Only while you use them | Your capture folder |

**Privacy mode** for screen sharing: *Settings › AI Usage › Hide prompts, commands and project names*.
NotchIsland can also hide itself from screenshots and screen sharing (*Settings › Island*).

## What uses the network

| Feature | Talks to | When |
|---|---|---|
| Weather | Open-Meteo (`api.open-meteo.com`), and Apple's geocoder for your city's name | When the Calendar section shows weather |
| Lyrics | LRCLIB (`lrclib.net`) | When lyrics are shown for a song |
| AI Usage · live limits *(opt-in)* | `api.anthropic.com` (Claude), `chatgpt.com` (Codex), `cli-chat-proxy.grok.com` (Grok) | Every few minutes while it matters; only for providers you switched on |
| AI Usage · API accounts *(opt-in)* | `openrouter.ai`, `api.openai.com`, `api.deepseek.com` | Every 10 minutes, only for keys you added |

### Live limits and sign-ins

Live limits read the sign-in the provider's own CLI already keeps on your Mac — Claude Code's in the
Keychain (`Claude Code-credentials`, so macOS asks you first), Codex's in `~/.codex/auth.json`, Grok
CLI's in `~/.grok/auth.json`. NotchIsland:

- sends that token **only** to its own provider, to read your usage;
- never writes it to disk, logs it, or shows it;
- never refreshes it (refreshing would rotate the CLI's sign-in and log it out).

API keys you add in Settings are stored in the macOS Keychain and sent only to their provider.

## Permissions

| Permission | Why |
|---|---|
| Accessibility | Notification mirroring, media control fallbacks, window snapping, paste |
| Screen & System Audio Recording | Screenshots, recording, the live video in the artwork, Copy Text |
| Camera / Microphone | The mirror, photos and videos; the microphone only while recording |
| Calendars | Upcoming meetings |
| Location | Weather and the Wi-Fi network name |
| Bluetooth | Accessory batteries |

You can grant only the ones for features you use; the rest of NotchIsland keeps working.

## Questions

Open a [discussion](https://github.com/prashanth-manchikatla/NotchIsland/discussions), or for anything sensitive follow
[SECURITY.md](../SECURITY.md).
