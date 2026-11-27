# Privacy

Hoverbird has **no accounts, no analytics and no telemetry**. It doesn't phone home, and it has no
server of its own. Everything below runs on your Mac; the few features that talk to the internet say so,
and each one is either essential to what you asked for or switched off until you turn it on.

## What stays on your Mac

| Feature | What it reads | Where results are kept |
|---|---|---|
| AI Usage | Logs your AI tools already write: `~/.claude`, `~/.codex`, `~/.gemini`, `~/.grok` | In memory only. Prompt text is shown in the app but never written anywhere by Hoverbird |
| Notes | — | `~/Library/Application Support/Hoverbird/notes.json` (owner-only) |
| Clipboard history | The clipboard (skipping password managers and concealed items) | Application Support, on this Mac |
| Notifications | Notification banners, through Accessibility | In memory |
| Copy Text / Scan QR | The area of the screen you select, read with Apple's on-device Vision | The clipboard |
| Focus | — | Daily focus minutes in preferences |
| Cinema · what's playing | Netflix's player controls (title, seek bar) through Accessibility, only while Netflix plays | In memory |
| Cinema · Theater | The streaming site you open in it | Its own website data on this Mac, like a browser's: your sign-ins (kept until you use **Settings › Cinema › Sign out of all**; sign-ins that sites would drop at quit are kept for 30 days), the Netflix profile you use there, and an encryption key for the site's stored data (`Application Support/Hoverbird/Theater/webcrypto.key`, owner-only — never the Keychain) |
| Camera & screen capture | Only while you use them | Your capture folder |

**Privacy mode** for screen sharing: *Settings › AI Usage › Hide prompts, commands and project names*.
Hoverbird can also hide itself from screenshots and screen sharing (*Settings › Island*).

## What uses the network

| Feature | Talks to | When |
|---|---|---|
| Weather | Open-Meteo (`api.open-meteo.com`), and Apple's geocoder for your city's name | When the Calendar section shows weather |
| Lyrics | LRCLIB (`lrclib.net`) | When lyrics are shown for a song — never for movies and shows |
| Cinema · Netflix picture | The title's public page on `www.netflix.com` (only its first few KB) and its image on Netflix's image servers (`*.nflxso.net`) — no cookies, nothing about you | Once per title, while it plays on Netflix |
| AI Usage · live limits *(opt-in)* | `api.anthropic.com` (Claude), `chatgpt.com` (Codex), `cli-chat-proxy.grok.com` (Grok) | Every few minutes while it matters; only for providers you switched on |
| AI Usage · API accounts *(opt-in)* | `openrouter.ai`, `api.openai.com`, `api.deepseek.com` | Every 10 minutes, only for keys you added |

### Live limits and sign-ins

Live limits read the sign-in the provider's own CLI already keeps on your Mac — Claude Code's in the
Keychain (`Claude Code-credentials`), Codex's in `~/.codex/auth.json`, Grok CLI's in
`~/.grok/auth.json`. Hoverbird:

- reads it only while you have live limits turned on — once per launch, and again when it expires;
- reads Claude Code's the same way Claude Code does, through Apple's `security` tool, so macOS
  doesn't show a password prompt;
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

You can grant only the ones for features you use; the rest of Hoverbird keeps working.

## Questions

Open a [discussion](https://github.com/prashanth-manchikatla/Hoverbird/discussions), or for anything sensitive follow
[SECURITY.md](../SECURITY.md).
