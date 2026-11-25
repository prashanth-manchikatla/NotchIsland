# Contributing to NotchIsland

Thanks for helping make NotchIsland better! Bug reports, ideas, documentation and code are all welcome.

- **Questions and ideas** → [Discussions](https://github.com/prashanth-manchikatla/NotchIsland/discussions)
- **Bugs and concrete feature requests** → [Issues](https://github.com/prashanth-manchikatla/NotchIsland/issues/new/choose)
- **Security problems** → privately, as described in [SECURITY.md](SECURITY.md)

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting set up

```bash
git clone https://github.com/prashanth-manchikatla/NotchIsland.git
cd NotchIsland
./Scripts/setup-signing.sh      # optional, once: keeps macOS permissions across rebuilds
./Scripts/build.sh --debug      # fast build → build/NotchIsland.app
./Scripts/build.sh --install    # optimized build, installed to /Applications and relaunched
```

Only the Command Line Tools are needed. See [docs/building.md](docs/building.md) for details and
troubleshooting, and [docs/architecture.md](docs/architecture.md) for how the code is organised.

## Making a change

1. **Talk first about big things.** For a new feature or a large refactor, open an issue or discussion
   before writing code, so we can agree on the approach.
2. **Branch** from `main`: `feat/short-description`, `fix/short-description`, `docs/…`.
3. **Keep it focused.** One feature or fix per pull request.
4. **Build and try it.** `./Scripts/build.sh` must succeed with no new warnings in the code you touched,
   and you should have used the feature yourself in the running app.
5. **Open a pull request** using the template, with screenshots or a short recording for anything
   visible.

### The NotchIsland way

These keep NotchIsland fast and trustworthy — reviews check for them:

- **No polling.** React to system events (FSEvents, notifications, property listeners). If something
  must sample, it runs only while its view is visible.
- **Cheap when idle.** Check idle CPU (≈ 0 %) and memory (`footprint <pid>`) before and after changes to
  anything that runs in the background.
- **Private by default.** Don't send data off the Mac unless the feature is exactly that, and make
  anything that reads another app's data or sign-in opt-in, with a clear explanation. Never log secrets.
- **Never steal focus.** The island window can't become key; use a non-activating panel for typing.
- **One feature, one folder** under `boringNotch/NotchIsland/`, starting with a short header comment that
  says what the file does and why.
- **Plain, friendly UI text.** Short labels, sentence case, no jargon.

### Code style

- Swift 5 language mode, 4-space indentation (see `.editorconfig`).
- Prefer clear names over comments; comment the *why*, not the *what*.
- Keep UI on `@MainActor`; do heavy work on a background queue and publish results to the main actor.
- Match the surrounding code. Upstream boring.notch files are kept close to upstream; mark NotchIsland
  changes in them with a `// NotchIsland:` comment.

### Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(ai): show subagents under each running agent
fix(camera): fall back to the Mac camera when the iPhone disconnects
docs: explain stable signing
```

Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `build`, `ci`, `chore`, `test`.

## Reporting a bug well

The bug form asks for your macOS version, your Mac, the NotchIsland version (*Settings › About*) and the
steps to reproduce. A screenshot or screen recording helps a lot. For iPhone and notification issues,
*Settings › iPhone & Notifications › Export diagnostics* writes a diagnostics file you can attach after
reviewing it.

## License

By contributing, you agree that your contributions are licensed under the
[GNU General Public License v3.0](LICENSE), the license of this project.
