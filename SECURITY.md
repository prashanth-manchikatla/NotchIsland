# Security policy

NotchIsland uses powerful macOS permissions (Accessibility, Screen Recording, Camera, Microphone) and can,
if you opt in, read the sign-in of AI command-line tools to show your usage limits. We take reports about
any of that seriously.

## Supported versions

| Version | Supported |
|---|---|
| Latest release (including betas) | ✅ |
| Older releases | ❌ — please update first |

## Reporting a vulnerability

**Please don't open a public issue for security problems.** Report them privately through GitHub:

1. Go to the repository's **Security** tab → **Report a vulnerability**
   ([direct link](https://github.com/prashanth-manchikatla/NotchIsland/security/advisories/new)).
2. Describe the issue, the impact, and how to reproduce it. A proof of concept helps.

You can expect an acknowledgement within **3 days** and an assessment within **7 days**. Once a fix is
released we'll publish an advisory and credit you, unless you'd rather stay anonymous.

## In scope

- Anything that lets another app or a website use NotchIsland's permissions.
- Leaks of data NotchIsland handles: clipboard history, notifications, notes, AI usage logs, or the
  AI sign-ins and API keys used by AI Usage.
- Network requests that send data somewhere [docs/privacy.md](docs/privacy.md) doesn't describe.

## Out of scope

- macOS asking for permissions again after an update of an ad-hoc signed build (expected; see
  [docs/building.md](docs/building.md)).
- Issues in the AI tools themselves, or in macOS.
