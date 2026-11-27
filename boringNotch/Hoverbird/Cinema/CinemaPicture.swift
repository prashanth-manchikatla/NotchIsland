//
//  CinemaPicture.swift
//  Hoverbird
//
//  VLC-style picture modes for full-screen video. On the Theater's whole 1.54:1 screen
//  (13" MacBook Air, 1710 × 1112 pt) a 16:9 show:
//    Fit      the whole picture, as made (black bars where the shapes differ)
//    Fill     zoomed ×1.16 until the screen is covered: about 7 % trimmed from each side
//    Smart    the default — covered with the smallest change: about 4 % trimmed from each
//             side and 7 % taller (the difference is split, the stretch capped at 10 %)
//    Stretch  covered without trimming: 16 % taller
//  plus Zoom (100–150 %) on top, for movies with black bars inside the video itself.
//
//  Streaming video is DRM-protected, so no other app can redraw it — but the page can
//  scale its own <video> element with CSS. In the Theater that's Hoverbird's own page; in
//  a Safari / Chrome-family tab the island asks the browser to run a small script there
//  (`do JavaScript` / `execute javascript`, each needs "Allow JavaScript from Apple Events"
//  once). The script stays in the page, follows the player when it re-sizes its video
//  (controls, quality changes, next episode) and only acts while the page is full screen.
//  Safari web apps (the Netflix app) and native apps (Prime Video) can't be reached by any
//  other app — and their full screen stays below the notch anyway — so choosing Fill, Smart,
//  Stretch or Zoom there moves the video into the Theater, where it applies.
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
        /// Moving the video into the Theater (the web app / app can't be resized).
        case opening
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
        if moveToTheaterIfNeeded() { return }
        apply()
    }

    func nudgeZoom(by delta: Double) {
        let zoom = min(1.5, max(1.0, ((Defaults[.cinemaZoom] + delta) * 100).rounded() / 100))
        Defaults[.cinemaZoom] = zoom
        if moveToTheaterIfNeeded() { return }
        apply()
    }

    /// The Netflix web app and native apps can't be resized from outside (and stay below the
    /// notch): Fill, Smart, Stretch and Zoom move the video into the Theater, where they apply.
    private func moveToTheaterIfNeeded() -> Bool {
        switch support {
        case .webApp, .app:
            // Fit at 100 % is what the app shows already.
            guard Defaults[.cinemaPictureMode] != .fit || Defaults[.cinemaZoom] > 1.001 else {
                status = .idle
                return true
            }
            guard MusicManager.shared.hasActiveMedia else { return false }
            generation += 1
            status = .opening
            CinemaTheater.shared.openForCurrentSource()
            return true
        default:
            return false
        }
    }

    /// The Theater couldn't open (no address for what's playing).
    func theaterFailed(_ message: String) {
        generation += 1
        status = .failed(message)
    }

    /// What the Theater's page applied (its own script runs at load, on resizes, on episodes).
    func theaterApplied(_ result: String) {
        guard CinemaTheater.shared.isOpen else { return }
        if case .working = status { return }
        let next = Self.status(for: .value(result), browser: ScriptBrowser(bundleID: "", name: "the Theater", isSafari: false),
                               mode: Defaults[.cinemaPictureMode])
        if next != status { status = next }
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
            if !result.hasPrefix("error") { theater.pictureApplied(result) }
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
    /// the mode on full screen changes, new videos (next episode) and resizes, plus a 1 s check
    /// while a mode is on, because players move and re-size their video on their own (Netflix's
    /// video box is taller than the screen; Prime Video's sits in a 16:9 frame).
    /// Players that clip their video to a frame the picture's shape (Prime Video) have that
    /// clipping lifted while a mode is on — otherwise the picture zooms but keeps its black bars
    /// — and put back for Fit. A player that scales its own frame scales the move as well; where
    /// the picture landed is checked and nudged once.
    /// Only the feature is resized: videos under 4 minutes (trailers in a page's header, previews,
    /// ads) are left alone. With object-fit: cover the picture you see is the video's box itself.
    /// Returns what it did: "smart:1.075:1.156:1920x1080:1710x1112:3.5:0.0" (mode : scale x :
    /// scale y : video : screen : % trimmed per side : % trimmed top/bottom), or fit / notfull /
    /// novideo / nosize.
    static func pageScript(mode: CinemaPictureMode, zoom: Double) -> String {
        let name: String
        switch mode {
        case .fit: name = "fit"
        case .fill: name = "fill"
        case .smart: name = "smart"
        case .stretch: name = "stretch"
        }
        let z = String(format: "%.3f", min(1.5, max(1.0, zoom)))
        return """
        (function(mode,zoom){var w=window,k='__hoverbirdCinema',s=w[k];\
        if(s&&s.ver!==4){if(s.iv)clearInterval(s.iv);s.apply=s.run=s.check=function(){return '';};s=null;}\
        if(!s){s=w[k]={ver:4,mode:'fit',zoom:1,result:'',iv:0,u:[],root:null,r2:null};\
        var full=function(){return !!(document.fullscreenElement||document.webkitFullscreenElement)||(w.innerWidth>=screen.width-2&&w.innerHeight>=screen.height-80);};\
        var clear=function(v){v.style.removeProperty('transform');v.style.removeProperty('transform-origin');delete v.dataset.hbCinema;};\
        var pick=function(){var b=null,a=0,l=document.querySelectorAll('video');for(var i=0;i<l.length;i++){var v=l[i],r=v.getBoundingClientRect(),x=r.width*r.height;\
        if(v.videoWidth>0&&!(isFinite(v.duration)&&v.duration<240)&&x>a){b=v;a=x;}}return b;};\
        var sig=function(v){return v?[v.offsetLeft,v.offsetTop,v.offsetWidth,v.offsetHeight,v.videoWidth,v.videoHeight,w.innerWidth,w.innerHeight,full()?1:0].join(','):'';};\
        var P=['overflow','clip-path','contain'];\
        var unclip=function(v,W,H){for(var e=v.parentElement;e&&e!==document.body&&e!==document.documentElement;e=e.parentElement){if(e.dataset.hbUnclip)continue;\
        var cs=getComputedStyle(e),q=e.getBoundingClientRect(),clips=cs.overflowX!=='visible'||cs.overflowY!=='visible'||(cs.clipPath&&cs.clipPath!=='none')||/paint|strict|content/.test(cs.contain||'');\
        if(clips&&(q.left>0.5||q.top>0.5||q.right<W-0.5||q.bottom<H-0.5)){s.u.push([e,P.map(function(p){return [p,e.style.getPropertyValue(p),e.style.getPropertyPriority(p)];})]);\
        e.dataset.hbUnclip='1';e.style.setProperty('overflow','visible','important');e.style.setProperty('clip-path','none','important');e.style.setProperty('contain','none','important');}}\
        if(!s.root){var d=document.documentElement.style;s.root=[d.getPropertyValue('overflow'),d.getPropertyPriority('overflow')];d.setProperty('overflow','hidden','important');}};\
        var reclip=function(){s.u.forEach(function(x){var e=x[0];x[1].forEach(function(p){e.style.removeProperty(p[0]);if(p[1])e.style.setProperty(p[0],p[1],p[2]);});delete e.dataset.hbUnclip;});s.u=[];\
        if(s.root){var d=document.documentElement.style;d.removeProperty('overflow');if(s.root[0])d.setProperty('overflow',s.root[0],s.root[1]);s.root=null;}};\
        var put=function(v,tx,ty,sx,sy){v.style.setProperty('transform-origin','50% 50%','important');\
        v.style.setProperty('transform','translate('+tx.toFixed(1)+'px,'+ty.toFixed(1)+'px) scale('+sx.toFixed(4)+','+sy.toFixed(4)+')','important');};\
        s.run=function(){var l=document.querySelectorAll('video[data-hb-cinema]');for(var i=0;i<l.length;i++)clear(l[i]);reclip();s.r2=null;\
        var v=pick();s.v=v;s.sig=sig(v);if(!v)return 'novideo';if(!full())return 'notfull';\
        if(s.mode==='fit'&&s.zoom<=1.001){var f=v.getBoundingClientRect();s.r2={l:f.left,t:f.top,w:f.width,h:f.height};return 'fit';}\
        var r=v.getBoundingClientRect(),vw=v.videoWidth,vh=v.videoHeight,W=w.innerWidth,H=w.innerHeight;\
        if(!r.width||!r.height||!vw||!vh)return 'nosize';\
        var of=getComputedStyle(v).objectFit,c=of==='cover'?Math.max(r.width/vw,r.height/vh):Math.min(r.width/vw,r.height/vh);\
        var dw=of==='fill'?r.width:vw*c,dh=of==='fill'?r.height:vh*c,sx,sy;if(of==='cover'){dw=Math.min(dw,r.width);dh=Math.min(dh,r.height);}\
        if(s.mode==='fill'){sx=sy=Math.max(W/dw,H/dh);}else if(s.mode==='stretch'){sx=W/dw;sy=H/dh;}\
        else if(s.mode==='smart'){var ac=dw/dh,as=W/H,st=Math.min(Math.sqrt(Math.max(ac,as)/Math.min(ac,as)),1.1);\
        if(ac>=as){sy=H/dh;sx=sy/st;}else{sx=W/dw;sy=sx/st;}if(dw*sx<W)sx=W/dw;if(dh*sy<H)sy=H/dh;}\
        else{sx=sy=Math.min(W/dw,H/dh);}\
        sx*=s.zoom;sy*=s.zoom;\
        var kx=v.offsetWidth?r.width/v.offsetWidth:1,ky=v.offsetHeight?r.height/v.offsetHeight:1;\
        var tx=(W/2-(r.left+r.width/2))/kx,ty=(H/2-(r.top+r.height/2))/ky;\
        put(v,tx,ty,sx,sy);v.dataset.hbCinema='1';unclip(v,W,H);\
        var q=v.getBoundingClientRect(),ex=q.left+q.width/2-W/2,ey=q.top+q.height/2-H/2;\
        if(Math.abs(ex)>1||Math.abs(ey)>1){tx-=ex/kx;ty-=ey/ky;put(v,tx,ty,sx,sy);q=v.getBoundingClientRect();}\
        s.r2={l:q.left,t:q.top,w:q.width,h:q.height};var cw=dw*sx,ch=dh*sy;\
        return s.mode+':'+sx.toFixed(3)+':'+sy.toFixed(3)+':'+vw+'x'+vh+':'+Math.round(W)+'x'+Math.round(H)+':'+(Math.max(0,cw-W)/2/cw*100).toFixed(1)+':'+(Math.max(0,ch-H)/2/ch*100).toFixed(1);};\
        s.apply=function(){s.result=s.run();return s.result;};\
        s.check=function(){var v=pick();if(v!==s.v||sig(v)!==s.sig)return s.apply();\
        if(v&&s.r2){var q=v.getBoundingClientRect();if(Math.abs(q.left-s.r2.l)>1||Math.abs(q.top-s.r2.t)>1||Math.abs(q.width-s.r2.w)>1||Math.abs(q.height-s.r2.h)>1)s.apply();}};\
        var later=function(){clearTimeout(s.t);s.t=setTimeout(function(){s.apply();},150);};\
        ['fullscreenchange','webkitfullscreenchange'].forEach(function(e){document.addEventListener(e,function(){later();setTimeout(function(){s.apply();},700);},true);});\
        ['loadedmetadata','playing','resize'].forEach(function(e){document.addEventListener(e,later,true);});\
        w.addEventListener('resize',later);[600,2000,5000].forEach(function(d){setTimeout(function(){s.apply();},d);});}\
        s.mode=mode;s.zoom=zoom;var on=mode!=='fit'||zoom>1.001;\
        if(on&&!s.iv)s.iv=setInterval(function(){s.check();},1000);else if(!on&&s.iv){clearInterval(s.iv);s.iv=0;}\
        return s.apply();})('\(name)',\(z))
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
            default:
                let picture = describe(value)
                return .applied(picture.map { "\($0.title) · \($0.detail)" } ?? mode.rawValue)
            }
        }
    }

    /// What a page-script result means on screen: ("Smart", "4% trimmed per side, 8% taller").
    static func describe(_ result: String) -> (title: String, detail: String)? {
        let zoom = Defaults[.cinemaZoom]
        let zoomText = zoom > 1.001 ? " \(Int((zoom * 100).rounded()))%" : ""
        if result == "fit" { return ("Fit", "whole picture, as made") }
        let parts = result.split(separator: ":").map(String.init)
        guard parts.count >= 3, let sx = Double(parts[1]), let sy = Double(parts[2]),
              let mode = CinemaPictureMode.allCases.first(where: { $0.rawValue.lowercased() == parts[0] }) else { return nil }
        let trimSide = parts.count >= 7 ? (Double(parts[5]) ?? 0) : 0
        let trimTop = parts.count >= 7 ? (Double(parts[6]) ?? 0) : 0
        let taller = (sy / sx - 1) * 100
        let wider = (sx / sy - 1) * 100
        var pieces: [String] = []
        if trimSide >= 0.5 { pieces.append("\(Int(trimSide.rounded()))% trimmed per side") }
        if trimTop >= 0.5 { pieces.append("\(Int(trimTop.rounded()))% trimmed top and bottom") }
        if taller >= 0.5 { pieces.append("\(Int(taller.rounded()))% taller") }
        if wider >= 0.5 { pieces.append("\(Int(wider.rounded()))% wider") }
        if pieces.isEmpty { pieces.append(mode == .fit ? "whole picture" : "whole screen") }
        if mode == .stretch, trimSide < 0.5, trimTop < 0.5 { pieces.insert("nothing trimmed", at: 0) }
        return (mode.rawValue + zoomText, pieces.joined(separator: ", "))
    }
}
