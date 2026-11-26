//
//  CinemaPicture.swift
//  Hoverbird
//
//  VLC-style picture modes for full-screen video:
//    Fit      the whole picture, as made (black bars where the shapes differ)
//    Fill     zoom until the screen is covered. On the 13" MacBook Air a full-screen app
//             gets 1470 × 924 pt (16:10) below the notch, so a 16:9 show is zoomed
//             ×1.12 and loses about 5 % on each side.
//    Stretch  cover the screen without trimming: the picture becomes ~12 % taller.
//  plus Zoom (100–150 %) on top, for movies with black bars inside the video itself.
//
//  Streaming video is DRM-protected, so no other app can redraw it — but the page can
//  scale its own <video> element with CSS. The island asks the browser to run a small
//  script in that tab: Safari's `do JavaScript`, Chrome-family `execute javascript`
//  (each needs "Allow JavaScript from Apple Events" once). The script stays in the page
//  and re-applies itself on full screen changes and new episodes; it only acts while
//  the page is full screen. Safari web apps and native apps (Prime Video) can't run
//  scripts from other apps — and their full screen stays below the notch anyway — so
//  the island offers the Theater (CinemaTheater: the whole 1.54:1 screen) instead.
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class CinemaPicture: ObservableObject {
    static let shared = CinemaPicture()

    struct ScriptBrowser: Equatable {
        let bundleID: String
        let name: String
        let isSafari: Bool
    }

    /// Where the video plays, and whether the picture mode can reach it.
    enum Support: Equatable {
        /// Hoverbird's own full-screen window (1.54:1, the whole display).
        case theater
        case script(ScriptBrowser)
        case webApp(name: String)
        case app(name: String)
        case none
    }

    enum Status: Equatable {
        case idle
        case working
        /// "Fill · ×1.12"
        case applied(String)
        case notFullScreen
        case noVideo
        /// The browser's "Allow JavaScript from Apple Events" is off.
        case needsJavaScript(ScriptBrowser)
        /// macOS › Privacy & Security › Automation doesn't allow Hoverbird → browser.
        case needsAutomation(ScriptBrowser)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let queue = DispatchQueue(label: "app.hoverbird.cinema.picture", qos: .userInitiated)
    private var generation = 0
    private var startTask: Task<Void, Never>?

    private static let chromium: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge", "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    private init() {}

    var support: Support {
        if CinemaTheater.shared.isOpen { return .theater }
        guard let id = MusicManager.shared.bundleIdentifier, !id.isEmpty else { return .none }
        return Self.support(for: id)
    }

    static func support(for id: String) -> Support {
        if id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" {
            return .script(ScriptBrowser(bundleID: id, name: "Safari", isSafari: true))
        }
        if let name = chromium[id] { return .script(ScriptBrowser(bundleID: id, name: name, isSafari: false)) }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? "This app"
        if id.hasPrefix("com.apple.Safari.WebApp") { return .webApp(name: name) }
        return .app(name: name)
    }

    // MARK: Changing the mode

    func setMode(_ mode: CinemaPictureMode) {
        Defaults[.cinemaPictureMode] = mode
        apply()
    }

    func nudgeZoom(by delta: Double) {
        let zoom = min(1.5, max(1.0, ((Defaults[.cinemaZoom] + delta) * 100).rounded() / 100))
        Defaults[.cinemaZoom] = zoom
        apply()
    }

    /// A video just went full screen: bring back the mode you picked last time.
    func cinemaStarted() {
        guard Defaults[.cinemaPictureMode] != .fit || Defaults[.cinemaZoom] > 1.001,
              case .script = support else { return }
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            // Let the full-screen animation finish so the page has its final size.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    func apply() {
        if CinemaTheater.shared.isOpen {
            applyInTheater()
            return
        }
        guard case .script(let browser) = support else {
            status = .idle
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first != nil else {
            status = .noVideo
            return
        }
        let mode = Defaults[.cinemaPictureMode]
        let zoom = Defaults[.cinemaZoom]
        let js = Self.pageScript(mode: mode, zoom: zoom)
        let domains = OTTDetector.domains(forPlatformNamed: LiveVideoManager.shared.ottPlatform?.name)
        let source = browser.isSafari
            ? Self.safariScript(bundleID: browser.bundleID, js: js, domains: domains)
            : Self.chromiumScript(bundleID: browser.bundleID, js: js, domains: domains)
        generation += 1
        let generation = generation
        status = .working
        queue.async {
            let result = Self.run(source)
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                self.status = Self.status(for: result, browser: browser, mode: mode)
                if IslandTuning.current.cinemaDebug == true {
                    IslandDebugLog.write("cinema-debug.txt", "picture \(mode.rawValue) zoom \(zoom) → \(result)")
                }
            }
        }
    }

    /// The Theater closed: its result no longer describes anything on screen.
    func theaterClosed() {
        generation += 1
        status = .idle
    }

    /// The Theater is Hoverbird's own web view: run the script there directly.
    private func applyInTheater() {
        let mode = Defaults[.cinemaPictureMode]
        let js = Self.pageScript(mode: mode, zoom: Defaults[.cinemaZoom])
        let theater = CinemaTheater.shared
        theater.pictureModeChanged()
        generation += 1
        let generation = generation
        status = .working
        Task { @MainActor [weak self] in
            let result = await theater.evaluate(js)
            guard let self, generation == self.generation else { return }
            self.status = result.hasPrefix("error")
                ? .failed(String(result.dropFirst(7)))
                : Self.status(for: .value(result), browser: ScriptBrowser(bundleID: "", name: "the Theater", isSafari: false), mode: mode)
        }
    }

    /// The address a browser or web app is showing (AXWebArea → AXURL).
    nonisolated static func webAreaURL(pid: pid_t) -> URL? {
        // Never our own process: WebKit's views may only be read on the main thread.
        guard AXIsProcessTrusted(), pid != getpid() else { return nil }
        let app = AX.app(pid: pid)
        var queue: [AXUIElement] = []
        if let value = AX.attribute(app, kAXMainWindowAttribute as String), CFGetTypeID(value) == AXUIElementGetTypeID() {
            queue.append(value as! AXUIElement)
        }
        queue += AX.elements(app, kAXWindowsAttribute as String)
        var index = 0
        while index < queue.count, index < 400 {
            let element = queue[index]
            index += 1
            if AX.role(element) == "AXWebArea" {
                if let value = AX.attribute(element, "AXURL") {
                    if let url = value as? URL, url.scheme?.hasPrefix("http") == true { return url }
                    if let text = value as? String, let url = URL(string: text), url.scheme?.hasPrefix("http") == true { return url }
                }
                continue
            }
            queue += AX.children(element)
        }
        return nil
    }

    // MARK: Scripts

    /// Runs inside the page. Idempotent: the first call installs listeners that re-apply
    /// the mode on full screen changes, new videos (next episode) and resizes.
    static func pageScript(mode: CinemaPictureMode, zoom: Double) -> String {
        let name: String
        switch mode {
        case .fit: name = "fit"
        case .fill: name = "fill"
        case .stretch: name = "stretch"
        }
        let z = String(format: "%.3f", min(1.5, max(1.0, zoom)))
        return """
        (function(mode,zoom){var w=window,k='__hoverbirdCinema',s=w[k];\
        if(!s){s=w[k]={mode:'fit',zoom:1};\
        var full=function(){return !!(document.fullscreenElement||document.webkitFullscreenElement)||(w.innerWidth>=screen.width-2&&w.innerHeight>=screen.height-80);};\
        var clear=function(v){v.style.removeProperty('transform');v.style.removeProperty('transform-origin');delete v.dataset.hbCinema;};\
        var pick=function(){var b=null,a=0,l=document.querySelectorAll('video');for(var i=0;i<l.length;i++){var v=l[i],r=v.getBoundingClientRect(),x=r.width*r.height;if(v.videoWidth>0&&x>a){b=v;a=x;}}return b;};\
        s.apply=function(){var l=document.querySelectorAll('video[data-hb-cinema]');for(var i=0;i<l.length;i++)clear(l[i]);\
        var v=pick();if(!v)return 'novideo';if(!full())return 'notfull';if(s.mode==='fit'&&s.zoom<=1.001)return 'fit';\
        var r=v.getBoundingClientRect(),vw=v.videoWidth,vh=v.videoHeight,W=w.innerWidth,H=w.innerHeight;\
        if(!r.width||!r.height||!vw||!vh)return 'nosize';\
        var of=getComputedStyle(v).objectFit,c=of==='cover'?Math.max(r.width/vw,r.height/vh):Math.min(r.width/vw,r.height/vh);\
        var dw=of==='fill'?r.width:vw*c,dh=of==='fill'?r.height:vh*c,sx,sy;\
        if(s.mode==='fill'){sx=sy=Math.max(W/dw,H/dh);}else if(s.mode==='stretch'){sx=W/dw;sy=H/dh;}else{sx=sy=Math.min(W/dw,H/dh);}\
        sx*=s.zoom;sy*=s.zoom;var tx=W/2-(r.left+r.width/2),ty=H/2-(r.top+r.height/2);\
        v.style.setProperty('transform-origin','50% 50%','important');\
        v.style.setProperty('transform','translate('+tx.toFixed(1)+'px,'+ty.toFixed(1)+'px) scale('+sx.toFixed(4)+','+sy.toFixed(4)+')','important');\
        v.dataset.hbCinema='1';return s.mode+':'+sx.toFixed(3)+':'+sy.toFixed(3)+':'+vw+'x'+vh+':'+Math.round(W)+'x'+Math.round(H);};\
        var later=function(){clearTimeout(s.t);s.t=setTimeout(s.apply,150);};\
        ['fullscreenchange','webkitfullscreenchange'].forEach(function(e){document.addEventListener(e,function(){later();setTimeout(s.apply,700);},true);});\
        ['loadedmetadata','playing','resize'].forEach(function(e){document.addEventListener(e,later,true);});\
        w.addEventListener('resize',later);[600,2000,5000].forEach(function(d){setTimeout(s.apply,d);});}\
        s.mode=mode;s.zoom=zoom;return s.apply();})('\(name)',\(z))
        """
    }

    /// AppleScript string literal.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func domainList(_ domains: [String]) -> String {
        "{" + domains.map(quoted).joined(separator: ", ") + "}"
    }

    /// The tab showing the service (front tab first), else the front tab.
    static func safariScript(bundleID: String, js: String, domains: [String]) -> String {
        """
        tell application id \(quoted(bundleID))
            set js to \(quoted(js))
            set wanted to \(domainList(domains))
            set chosen to missing value
            try
                set t to current tab of front window
                set u to URL of t
                repeat with d in wanted
                    if u contains (d as text) then set chosen to t
                end repeat
            end try
            if chosen is missing value and (count of wanted) > 0 then
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            set u to URL of t
                            repeat with d in wanted
                                if u contains (d as text) then set chosen to t
                            end repeat
                            if chosen is not missing value then exit repeat
                        end repeat
                    end try
                    if chosen is not missing value then exit repeat
                end repeat
            end if
            if chosen is missing value then
                try
                    set chosen to current tab of front window
                on error
                    return "notab"
                end try
            end if
            return do JavaScript js in chosen
        end tell
        """
    }

    static func chromiumScript(bundleID: String, js: String, domains: [String]) -> String {
        """
        tell application id \(quoted(bundleID))
            set js to \(quoted(js))
            set wanted to \(domainList(domains))
            set chosen to missing value
            try
                set t to active tab of front window
                set u to URL of t
                repeat with d in wanted
                    if u contains (d as text) then set chosen to t
                end repeat
            end try
            if chosen is missing value and (count of wanted) > 0 then
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            set u to URL of t
                            repeat with d in wanted
                                if u contains (d as text) then set chosen to t
                            end repeat
                            if chosen is not missing value then exit repeat
                        end repeat
                    end try
                    if chosen is not missing value then exit repeat
                end repeat
            end if
            if chosen is missing value then
                try
                    set chosen to active tab of front window
                on error
                    return "notab"
                end try
            end if
            return execute chosen javascript js
        end tell
        """
    }

    private enum RunResult: CustomStringConvertible {
        case value(String)
        case error(number: Int, message: String)
        var description: String {
            switch self {
            case .value(let v): return "ok \(v)"
            case .error(let n, let m): return "error \(n): \(m)"
            }
        }
    }

    /// NSAppleScript is used from this one serial queue only.
    nonisolated private static func run(_ source: String) -> RunResult {
        guard let script = NSAppleScript(source: source) else { return .error(number: 0, message: "Couldn't build the script") }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            return .error(number: number, message: message)
        }
        return .value(descriptor.stringValue ?? "")
    }

    private static func status(for result: RunResult, browser: ScriptBrowser, mode: CinemaPictureMode) -> Status {
        switch result {
        case .error(let number, let message):
            let text = message.lowercased()
            if number == -1743 || number == -10004 || text.contains("not authorized") || text.contains("not allowed to send") {
                return .needsAutomation(browser)
            }
            if text.contains("javascript") && (text.contains("apple events") || text.contains("applescript") || text.contains("turned off")) {
                return .needsJavaScript(browser)
            }
            return .failed(message)
        case .value(let value):
            switch value {
            case "notab", "novideo", "nosize": return .noVideo
            case "notfull": return .notFullScreen
            case "fit": return .applied("Fit")
            default:
                // "fill:1.118:1.118:1920x1080:1470x924"
                let parts = value.split(separator: ":")
                guard parts.count >= 3, let sx = Double(parts[1]), let sy = Double(parts[2]) else { return .applied(mode.rawValue) }
                let scale = abs(sx - sy) < 0.001 ? String(format: "×%.2f", sx) : String(format: "×%.2f wide, ×%.2f tall", sx, sy)
                return .applied("\(mode.rawValue) · \(scale)")
            }
        }
    }
}
