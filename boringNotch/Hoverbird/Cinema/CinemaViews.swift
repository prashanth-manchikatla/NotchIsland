//
//  CinemaViews.swift
//  Hoverbird
//
//  The Cinema card on Home (next to the player while a streaming service plays) and
//  Settings › Cinema.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Card

struct CinemaCard: View {
    let platform: OTTPlatform
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var picture = CinemaPicture.shared
    @ObservedObject private var theater = CinemaTheater.shared
    @Default(.cinemaPictureMode) private var mode
    @Default(.cinemaZoom) private var zoom
    @State private var flash: String?
    @State private var flashTask: Task<Void, Never>?
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showSteps, let browser = blockedBrowser {
                steps(for: browser)
            } else {
                header
                modePicker
                actionRow
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(10)
        .frame(width: 214, height: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: flash)
        // While you look at the card, the page is read more often (fresh title and time).
        .onAppear { CinemaNowPlaying.shared.setViewing(true) }
        .onDisappear {
            flashTask?.cancel()
            CinemaNowPlaying.shared.setViewing(false)
        }
    }

    // MARK: Rows

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "film.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(platform.tint == .white ? Color.white : platform.tint)
            TimelineView(.periodic(from: .now, by: music.isPlaying ? 10 : 3600)) { context in
                Text(CinemaTime.line(music: music, now: context.date) ?? "Cinema")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CinemaPictureMode.allCases) { option in
                Button {
                    picture.setMode(option)
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(option == mode ? Color.black : Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background(Capsule().fill(option == mode ? Color.white : Color.white.opacity(0.09)))
                        .contentShape(Capsule())
                }
                .help(option.help)
                .accessibilityIdentifier("cinema.mode.\(option.rawValue)")
            }
        }
        .opacity(canResize ? 1 : 0.5)
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            Button {
                Task { await skip() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "forward.end.fill").font(.system(size: 9, weight: .bold))
                    Text("Skip").font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.13)))
                .contentShape(Capsule())
            }
            .help("Skip intro or recap, or play the next episode")
            .accessibilityIdentifier("cinema.skip")

            CinemaIconButton(symbol: "speaker.slash.fill", help: "Mute / unmute") {
                say(CinemaControls.toggleMute() ? "Mute switched" : blockedText)
            }
            CinemaIconButton(symbol: theater.isOpen ? "xmark" : "arrow.up.left.and.arrow.down.right",
                             help: theater.isOpen ? "Leave the full-screen Theater" : "The player's own full screen on / off") {
                if !CinemaControls.toggleFullScreen() { say(blockedText) }
            }
            Spacer(minLength: 2)
            zoomControl
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 1) {
            CinemaIconButton(symbol: "minus", size: 18, help: "Zoom out") { picture.nudgeZoom(by: -0.05) }
                .disabled(zoom <= 1.0)
                .opacity(zoom <= 1.0 ? 0.35 : 1)
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 31)
            CinemaIconButton(symbol: "plus", size: 18, help: "Zoom in — for movies with black bars inside the picture") {
                picture.nudgeZoom(by: 0.05)
            }
            .disabled(zoom >= 1.5)
            .opacity(zoom >= 1.5 ? 0.35 : 1)
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .opacity(canResize ? 1 : 0.5)
    }

    @ViewBuilder
    private var footer: some View {
        if let flash {
            Text(flash)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .transition(.opacity)
        } else if theater.isOpen {
            HStack(spacing: 6) {
                note(theaterStatus)
                Spacer(minLength: 0)
                smallButton("Exit", id: "cinema.exitTheater") { theater.close() }
                    .help("Leave the Theater (Esc)")
            }
        } else {
            HStack(spacing: 6) {
                sourceStatus
                Spacer(minLength: 0)
                smallButton("Full 1.54:1", id: "cinema.theater") { theater.openForCurrentSource() }
                    .help("Watch on the whole screen, beside the notch too, in Hoverbird's Theater")
            }
        }
    }

    private var theaterStatus: String {
        if case .applied(let text) = picture.status { return text }
        if case .failed(let message) = picture.status { return message }
        return "\(mode.rawValue) · whole screen"
    }

    /// What the picture mode can do where the video is playing now.
    @ViewBuilder
    private var sourceStatus: some View {
        switch picture.support {
        case .script(let browser):
            switch picture.status {
            case .needsJavaScript:
                Button { showSteps = true } label: {
                    Text("\(browser.name): one setting needed ›").font(.system(size: 9.5)).foregroundStyle(.orange)
                        .lineLimit(2).minimumScaleFactor(0.85)
                }
            case .needsAutomation:
                Button { CinemaPicture.openAutomationSettings() } label: {
                    Text("Allow control of \(browser.name) ›").font(.system(size: 9.5)).foregroundStyle(.orange)
                        .lineLimit(2).minimumScaleFactor(0.85)
                }
            case .working:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    note("Applying \(mode.rawValue)…")
                }
            default:
                note(CinemaPicture.statusText(picture.status, mode: mode, browser: browser.name))
            }
        case .webApp, .app:
            switch picture.status {
            case .opening:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    note("Opening the Theater…")
                }
            case .failed(let message):
                note(message)
            default:
                note("Fill, Smart and Stretch play in the Theater")
            }
        default:
            note("Whole screen, beside the notch too")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.gray)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
    }

    private func steps(for browser: CinemaPicture.ScriptBrowser) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Let Hoverbird resize the video")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
            Text(CinemaPicture.javaScriptSteps(browser))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                smallButton("Try again", id: "cinema.retry") {
                    showSteps = false
                    picture.apply()
                }
                smallButton("Close", id: "cinema.closeSteps") { showSteps = false }
            }
        }
    }

    private func smallButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .fixedSize()
        .accessibilityIdentifier(id)
    }

    // MARK: Helpers

    private var canResize: Bool {
        switch picture.support {
        case .script, .theater, .webApp, .app: return true // web apps & apps: via the Theater
        case .none: return false
        }
    }

    private var blockedBrowser: CinemaPicture.ScriptBrowser? {
        if case .needsJavaScript(let browser) = picture.status { return browser }
        return nil
    }

    private var blockedText: String {
        CinemaControls.canControl ? "The player isn't reachable" : "Allow Accessibility for Hoverbird"
    }

    private func skip() async {
        switch await CinemaControls.skip() {
        case .pressed(let label): say(label.capitalized(with: nil))
        case .sentShortcut: say("Skip sent to Netflix")
        case .nothing: say(CinemaControls.canControl ? "Nothing to skip right now" : blockedText)
        }
    }

    private func say(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            flash = nil
        }
    }
}

struct CinemaIconButton: View {
    let symbol: String
    var size: CGFloat = 24
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.11)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityIdentifier("cinema.\(symbol)")
    }
}

// MARK: - Time left

enum CinemaTime {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "42m left · ends 10:42 PM" (no end time while paused).
    @MainActor
    static func line(music: MusicManager, now: Date) -> String? {
        let duration = music.songDuration
        guard duration >= 60 else { return nil }
        var elapsed = music.elapsedTime
        if music.isPlaying { elapsed += now.timeIntervalSince(music.timestampDate) * music.playbackRate }
        let left = max(0, duration - elapsed)
        let minutes = Int((left / 60).rounded(.up))
        let leftText = minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m left" : "\(minutes)m left"
        guard music.isPlaying, music.playbackRate > 0.05 else { return "\(leftText) · paused" }
        let end = now.addingTimeInterval(left / music.playbackRate)
        return "\(leftText) · ends \(clock.string(from: end))"
    }
}

// MARK: - Shared texts

extension CinemaPicture {
    static func javaScriptSteps(_ browser: ScriptBrowser) -> String {
        if browser.isSafari {
            return "Safari › Settings › Advanced: turn on “Show features for web developers”. Then Settings › Developer: turn on “Allow JavaScript from Apple Events”."
        }
        return "In \(browser.name): View › Developer › Allow JavaScript from Apple Events."
    }

    static func statusText(_ status: Status, mode: CinemaPictureMode, browser: String) -> String {
        switch status {
        case .idle: return mode == .fit ? "Fill or Stretch to use the whole screen" : "\(mode.rawValue) turns on in full screen"
        case .working: return "Applying \(mode.rawValue)…"
        case .opening: return "Opening the Theater…"
        case .applied(let text): return text
        case .notFullScreen: return "\(mode.rawValue) turns on in full screen"
        case .noVideo: return "No video found in \(browser)"
        case .needsJavaScript(let b): return "\(b.name): turn on Allow JavaScript from Apple Events"
        case .needsAutomation(let b): return "Allow Hoverbird to control \(b.name) (Privacy › Automation)"
        case .failed(let message): return message
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings

struct CinemaSettingsView: View {
    @Default(.cinemaPictureMode) private var mode
    @Default(.cinemaZoom) private var zoom
    @ObservedObject private var picture = CinemaPicture.shared
    @State private var signedOut = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle("Cinema mode", key: .cinemaModeEnabled)
                Defaults.Toggle("Hold notifications while a video is full screen", key: .cinemaHoldNotifications)
                Defaults.Toggle("Show what you missed when you leave full screen", key: .cinemaSummary)
                Defaults.Toggle("Opening the island shows the player", key: .cinemaOpenToPlayer)
            } header: {
                Text("Full-screen video")
            } footer: {
                Text("While Netflix, Prime Video, YouTube or another video plays full screen, the island stays a plain black notch and notification banners wait until you leave full screen. A ringing timer, a recording or a nearly empty battery still show. Hover the notch for the player: ±10 s, Skip intro, mute, full screen and time left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Open in the Theater")
                    Spacer()
                    Button("Netflix") { CinemaTheater.shared.open(url: URL(string: "https://www.netflix.com/browse")!) }
                    Button("Prime Video") { CinemaTheater.shared.open(url: URL(string: "https://www.primevideo.com")!) }
                }
                HStack {
                    Text("Sign-ins are kept in Hoverbird's own website data")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign out of all") {
                        Task { await CinemaTheater.removeWebsiteData(); signedOut = true }
                    }
                    .disabled(signedOut)
                }
            } header: {
                Text("Theater — the whole 1.54:1 screen")
            } footer: {
                Text("macOS keeps every full-screen app (Safari, the Netflix web app, Prime Video) below the notch, in a 16:10 area. The Theater is Hoverbird's own window over the whole display, beside the notch too, like VLC's full screen: menu bar and Dock hidden, the service's website inside. Sign in once — it stays signed in, and it never asks for your Mac's password. From the island, “Full 1.54:1” (or Fill, Smart, Stretch while the Netflix app plays) moves what's playing into it. A changes the picture; Esc or ⌘W leaves; ⌘[ goes back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Picture", selection: Binding(get: { mode }, set: { picture.setMode($0) })) {
                    ForEach(CinemaPictureMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Zoom")
                    Slider(value: Binding(get: { zoom }, set: { Defaults[.cinemaZoom] = ($0 * 100).rounded() / 100 }),
                           in: 1.0...1.5, step: 0.05) { editing in
                        if !editing { picture.apply() }
                    }
                    Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text(statusLine).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Apply now") { picture.apply() }
                }
            } header: {
                Text("Picture — Fit, Fill, Smart, Stretch")
            } footer: {
                Text("In the Theater the screen is 1.54:1, so a 16:9 show can only cover it by trimming or stretching. Fit keeps the whole picture (thin bars above and below, the notch sits in the top bar). Fill zooms ×1.16 and trims about 7 % from each side. Smart (the default) splits the difference: about 4 % trimmed from each side and 8 % taller. Stretch trims nothing and makes it 16 % taller. With Fill, Smart and Stretch the notch covers a little of the top centre, as in VLC. Wide movies (2.39:1): try Fit with Zoom 120–130 %.\n\nThe picture modes also work in a Safari or Brave/Chrome tab in normal full screen (16:10, below the notch) after you turn on “Allow JavaScript from Apple Events” once (Safari › Settings › Developer; Brave/Chrome › View › Developer). The Netflix web app and the Prime Video app can't be resized by other apps: choosing a mode there moves the video into the Theater.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cinema")
    }

    private var statusLine: String {
        switch picture.support {
        case .script(let browser): return CinemaPicture.statusText(picture.status, mode: mode, browser: browser.name)
        case .theater: return CinemaPicture.statusText(picture.status, mode: mode, browser: "the Theater")
        case .webApp(let name), .app(let name): return "\(name) can't be resized from outside — modes open the Theater"
        case .none: return "Nothing is playing"
        }
    }
}
