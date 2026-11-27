//
//  CinemaTheater.swift
//  Hoverbird
//
//  Full-screen streaming at the MacBook's own shape — 1.54:1 on the 13" Air (2560 × 1664).
//
//  macOS always puts full-screen apps (Safari, Safari web apps, Prime Video) BELOW the
//  notch, in a 16:10 area. Like VLC's non-native full screen, the Theater is Hoverbird's
//  own borderless window over the whole display — the strip beside the notch included —
//  with the menu bar and Dock hidden and the service's website inside. Netflix and Prime
//  Video play there with FairPlay, the same DRM Safari uses. You sign in once; the sign-in
//  stays in Hoverbird's own website data (Settings › Cinema can remove it).
//
//  Fit / Fill / Stretch then work against the full 1.54:1 screen. With Fill or Stretch
//  the notch sits over the top edge of the picture, as in VLC.
//
//  Nothing runs until you open it; closing it tears the web view down.
//
//  Keys: Esc or ⌘W leave · A changes the picture (Fit, Fill, Smart, Stretch — like VLC) ·
//  ⌘[ back · ⌘] forward · ⌘R reload. Everything else goes to the player (space, ← →, M…).
//  A small note under the notch says which picture mode is on and what it trims.
//
//  Once a second the Theater reads the page (title, episode, position, length) for the
//  island's player — macOS Now Playing only hears "Netflix" from Netflix.
//

import AppKit
import Combine
import Defaults
import WebKit

extension Defaults.Keys {
    /// The Netflix profile the Theater uses (picked for you on "Who's watching?").
    static let theaterNetflixProfile = Key<String>("theaterNetflixProfile", default: "")
    /// The Theater's website data was reset once for its own WebCrypto key (TheaterCryptoKey).
    static let theaterOwnCryptoKey = Key<Bool>("theaterOwnCryptoKey", default: false)
}

/// Sites keep encryption keys in their page database (Netflix keeps its playback security keys
/// there), and WebKit locks them with a "WebCrypto master key". By default WebKit stores that
/// key in the login Keychain, tied to this exact build of Hoverbird — after every update macOS
/// asked for the login password each time the page touched a key, over and over. The Theater
/// gives WebKit its own key instead: 32 random bytes in Application Support/Hoverbird/Theater,
/// readable only by you, next to the website data it protects. The Keychain is never used.
enum TheaterCryptoKey {
    static let key: Data = {
        let folder = IslandPaths.appSupportPath.appendingPathComponent("Theater", isDirectory: true)
        let url = folder.appendingPathComponent("webcrypto.key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        let data = Data(bytes)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // If it can't be saved, this session still works (its pages just start fresh next time).
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        return data
    }()
}

/// Borderless windows can't become key by default; the Theater needs the keyboard.
final class TheaterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CinemaTheater: NSObject, ObservableObject {
    static let shared = CinemaTheater()

    @Published private(set) var isOpen = false
    /// The service on screen (from the address), shown in the island.
    @Published private(set) var platform: OTTPlatform?

    private var window: TheaterWindow?
    private var webView: WKWebView?
    private var note: TheaterNote?
    private var pageTimer: Timer?
    /// What the note last described.
    private var notedPicture: String?
    /// From the last page check: a video is on the page, and you're typing in a field.
    private var pageHasVideo = false
    private var pageTyping = false
    /// Moved here from something that was playing: start the feature once it's ready.
    private var resumeOnLoad = false
    private var resumeUntil = Date.distantPast
    /// The sign-in tip was shown for this page.
    private var notedSignIn: String?
    /// The way out, always: shown beside the notch when the Theater opens and when the pointer moves.
    private var leaveButton: TheaterLeaveButton?
    private var lastEscape = Date.distantPast
    /// What you opened (Netflix's "Who's watching?" can send you Home instead).
    private var intendedURL: URL?
    private var profilePickedAt = Date.distantPast
    private var keyMonitor: Any?
    /// Esc from anywhere while the Theater is what you see (another app may hold the keyboard).
    private var globalKeyMonitor: Any?
    /// A click on Leave Theater that macOS gave to another app (its menu bar owns the top strip).
    private var globalClickMonitor: Any?
    private var activeObserver: Any?
    private var resignObserver: Any?
    private var previousApp: NSRunningApplication?

    /// Above the menu bar: at normal level macOS covers the strip beside the notch with black
    /// (as in normal full screen). The island (mainMenu + 3) stays above the Theater.
    private static let theaterLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    private override init() {}

    // MARK: Open / close

    /// Moves what's playing (Safari tab, Netflix web app, Prime Video app…) into the Theater.
    func openForCurrentSource() {
        let music = MusicManager.shared
        let id = music.bundleIdentifier ?? ""
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
        // Apps have no address to hand over; Prime Video's app names the title it plays, and its
        // website resumes that title at a given second (the same link its own "Resume" uses).
        // Where you are, so the Theater carries on from the same second (0 = unknown).
        let position = music.songDuration > 0 ? music.estimatedPlaybackPosition() : 0
        let wasPlaying = music.isPlaying
        let fallback = Self.appTitleURL(bundleID: id, contentID: music.contentID, position: position)
            ?? OTTDetector.homeURL(forPlatformNamed: LiveVideoManager.shared.ottPlatform?.name)
        // Netflix: the title Hoverbird already follows (its id + your second) — no need to read the
        // web app's address, which a full-screen web app on another Space doesn't always give.
        let known = CinemaNowPlaying.shared.netflixWatchURL(for: id, position: position)
        if wasPlaying { music.pause() }
        Task.detached(priority: .userInitiated) {
            // Browsers and web apps show the page's address through Accessibility.
            let url = known ?? pid.flatMap { CinemaPicture.webAreaURL(pid: $0) }.map { Self.startingAt($0, seconds: position) } ?? fallback
            await MainActor.run {
                guard let url else {
                    CinemaPicture.shared.theaterFailed("Couldn't find the page to open in the Theater")
                    return
                }
                let theater = CinemaTheater.shared
                theater.resumeOnLoad = wasPlaying
                theater.resumeUntil = Date().addingTimeInterval(60)
                theater.open(url: url)
            }
        }
    }

    func open(url: URL) {
        // Pages saved before the Theater had its own WebCrypto key (see TheaterCryptoKey) hold
        // keys locked with the old Keychain one: clear them once — sign-ins (cookies) stay.
        if !Defaults[.theaterOwnCryptoKey] {
            Task { @MainActor in
                await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeIndexedDBDatabases],
                                                              modifiedSince: .distantPast)
                Defaults[.theaterOwnCryptoKey] = true
                self.open(url: url)
            }
            return
        }
        // The Theater is for the whole screen: Fit at 100 % (the same picture, with bars, as normal
        // full screen) starts as Smart, your whole-screen default. A or the island switch back.
        if Defaults[.cinemaPictureMode] == .fit, Defaults[.cinemaZoom] <= 1.001 {
            Defaults[.cinemaPictureMode] = .smart
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        platform = Self.platform(for: url)
        intendedURL = url
        notedPicture = nil
        notedSignIn = nil
        TheaterSignIns.shared.start()
        if let webView {
            load(url, in: webView)
            show()
            return
        }

        let screen = Self.targetScreen()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
        web.customUserAgent = Self.safariUserAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        web.underPageBackgroundColor = .black
        web.allowsBackForwardNavigationGestures = true
        web.autoresizingMask = [.width, .height]
        installPictureScript(in: web)

        // The whole display, the strip beside the notch included (borderless windows aren't
        // pushed below the menu bar).
        let window = TheaterWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.title = "Hoverbird Theater"
        // The page, with the picture-mode note on top of it.
        let container = TheaterContainer(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        web.frame = container.bounds
        container.addSubview(web)
        let note = TheaterNote()
        container.addSubview(note)
        let leave = TheaterLeaveButton()
        leave.onClick = { CinemaTheater.shared.close() }
        container.addSubview(leave)
        container.onMouseMove = { CinemaTheater.shared.showLeaveButton() }
        window.contentView = container
        leaveButton = leave
        self.window = window
        webView = web
        self.note = note
        isOpen = true
        load(url, in: web)
        installMonitors()
        // Title, time and picture for the island (cheap: one small script a second).
        pageTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { CinemaTheater.shared.checkPage() }
        }
        show()
    }

    func close() {
        guard isOpen else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalKeyMonitor = nil
        globalClickMonitor = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        activeObserver = nil
        resignObserver = nil
        pageTimer?.invalidate()
        pageTimer = nil
        note = nil
        notedPicture = nil
        pageHasVideo = false
        pageTyping = false
        resumeOnLoad = false
        notedSignIn = nil
        leaveButton = nil
        TheaterSignIns.shared.stop()
        NSApp.presentationOptions = []
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        webView = nil
        isOpen = false
        platform = nil
        CinemaPicture.shared.theaterClosed()
        CinemaNowPlaying.shared.theaterClosed()
        previousApp?.activate()
        previousApp = nil
        IslandMemory.trimSoon()
    }

    // MARK: Used by the island

    /// Gives the page the keyboard (the island's own panel may have taken it).
    func focusPage() {
        guard let window, let webView else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    /// Runs JavaScript in the page; the result as text ("" if none).
    func evaluate(_ js: String) async -> String {
        guard let webView else { return "" }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(returning: "error: \(error.localizedDescription)") }
                else { continuation.resume(returning: (value as? String) ?? (value.map { "\($0)" } ?? "")) }
            }
        }
    }

    /// A picture mode was applied in the page: say so under the notch when it's new.
    func pictureApplied(_ result: String) {
        CinemaPicture.shared.theaterApplied(result)
        guard let picture = CinemaPicture.describe(result), let note, let screen = window?.screen ?? NSScreen.main else { return }
        // Keyed on what the page actually applied (a page check can still report the last mode).
        let key = picture.title + "|" + picture.detail
        guard key != notedPicture else { return }
        notedPicture = key
        note.show(title: picture.title, detail: picture.detail + " · A changes it", belowTop: screen.safeAreaInsets.top + 14)
    }

    /// Once a second: what's playing (for the island) and what the picture script did.
    private func checkPage() {
        guard isOpen, let webView else { return }
        webView.evaluateJavaScript(Self.pageInfoScript) { value, _ in
            MainActor.assumeIsolated {
                let theater = CinemaTheater.shared
                guard theater.isOpen, let text = value as? String, let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                theater.pageHasVideo = (json["hasVideo"] as? Bool) ?? false
                theater.pageTyping = (json["typing"] as? Bool) ?? false
                theater.resumeIfNeeded(json)
                theater.tipIfSigningIn(json)
                theater.handleProfileGate(json)
                if let picture = json["pic"] as? String, !picture.isEmpty, !["novideo", "notfull", "nosize"].contains(picture) {
                    theater.pictureApplied(picture)
                }
                CinemaNowPlaying.shared.theaterPage(json)
            }
        }
    }

    /// After a move from something that was playing: start the feature as soon as it's ready
    /// (pages opened by an app don't start by themselves — Netflix shows a play button).
    private func resumeIfNeeded(_ json: [String: Any]) {
        guard resumeOnLoad else { return }
        guard Date() < resumeUntil else { resumeOnLoad = false; return }
        guard let ready = json["mvr"] as? Int, ready >= 3 else { return }
        resumeOnLoad = false
        guard (json["mvp"] as? Bool) == true else { return } // already playing
        webView?.evaluateJavaScript(Self.playScript, completionHandler: nil)
    }

    /// Netflix's "Who's watching?" (every new session): pick your profile for you — the one you
    /// use in the Theater, else the account's own (first, never a kids profile) — and go on to what
    /// you were opening.
    private func handleProfileGate(_ json: [String: Any]) {
        if let profile = json["nfp"] as? String, !profile.isEmpty, Defaults[.theaterNetflixProfile] != profile {
            Defaults[.theaterNetflixProfile] = profile
        }
        guard (json["gate"] as? Bool) == true, Date().timeIntervalSince(profilePickedAt) > 3, let webView else { return }
        profilePickedAt = Date()
        let wanted = Defaults[.theaterNetflixProfile].filter { $0.isLetter || $0.isNumber }
        webView.evaluateJavaScript(Self.pickProfileScript.replacingOccurrences(of: "__WANTED__", with: wanted)) { _, _ in
            MainActor.assumeIsolated {
                // Netflix shows Home after the profile; carry on to the title you were opening.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    MainActor.assumeIsolated {
                        let theater = CinemaTheater.shared
                        guard theater.isOpen, let intended = theater.intendedURL, intended.path.contains("/watch/"),
                              let web = theater.webView, web.url?.path.contains("/watch/") != true else { return }
                        web.load(URLRequest(url: intended))
                    }
                }
            }
        }
    }

    private static let pickProfileScript = #"""
    (function(want){var tiles=[].slice.call(document.querySelectorAll('button[data-uia^="profile-selector+tile-"]'));if(!tiles.length)return 'none';
    var id=function(b){return (b.getAttribute('data-uia')||'').replace('profile-selector+tile-','');};
    var pick=want?tiles.filter(function(b){return id(b)===want;})[0]:null;
    if(!pick)pick=tiles.filter(function(b){return !/\b(kids|children|child)\b/i.test(b.innerText||'');})[0]||tiles[0];
    pick.click();return 'picked '+id(pick);})('__WANTED__')
    """#

    /// On a sign-in page: one note, so the Theater keeps you signed in for good.
    private func tipIfSigningIn(_ json: [String: Any]) {
        guard (json["login"] as? Bool) == true, let path = (json["u"] as? String).flatMap(URL.init(string:))?.path,
              notedSignIn != path, let note, let screen = window?.screen ?? NSScreen.main else { return }
        notedSignIn = path
        note.show(title: "Sign in once",
                  detail: "Tick “Keep me signed in” if it's offered — the Theater remembers your sign-in",
                  belowTop: screen.safeAreaInsets.top + 14, seconds: 6)
    }

    /// Netflix's player API when it's there (keeps its controls in step), else the feature's video.
    private static let playScript = """
    (function(){try{var vp=netflix.appContext.state.playerApp.getAPI().videoPlayer,ids=vp.getAllPlayerSessionIds();\
    if(ids&&ids.length){vp.getVideoPlayerBySessionId(ids[ids.length-1]).play();return 'netflix';}}catch(e){}\
    var mv=null,ma=0;document.querySelectorAll('video').forEach(function(x){var r=x.getBoundingClientRect(),q=r.width*r.height;\
    if(x.videoWidth>0&&!(isFinite(x.duration)&&x.duration<240)&&q>ma){ma=q;mv=x;}});\
    if(mv){var p=mv.play();if(p&&p.catch)p.catch(function(){});return 'video';}return 'none';})()
    """

    /// Netflix pages start where you are with ?t=<seconds> (verified); other pages as they are.
    nonisolated static func startingAt(_ url: URL, seconds: TimeInterval) -> URL {
        guard seconds >= 5, url.host?.hasSuffix("netflix.com") == true, url.path.contains("/watch/"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "t" }
        items.append(URLQueryItem(name: "t", value: String(Int(seconds))))
        components.queryItems = items
        return components.url ?? url
    }

    /// Reads the page: Netflix's player (position, length, paused, title id), the title in its
    /// controls (remembered while they're hidden), or what other sites tell Now Playing.
    private static let pageInfoScript = """
    (function(){var o={u:location.href},c=window.__hbInfo||(window.__hbInfo={});\
    try{var api=window.netflix&&netflix.appContext&&netflix.appContext.state&&netflix.appContext.state.playerApp&&netflix.appContext.state.playerApp.getAPI();\
    var vp=api&&api.videoPlayer;if(vp){var ids=vp.getAllPlayerSessionIds();if(ids&&ids.length){var p=vp.getVideoPlayerBySessionId(ids[ids.length-1]);\
    if(p){var ct=p.getCurrentTime(),du=p.getDuration();if(isFinite(ct))o.p=ct/1000;if(isFinite(du)&&du>0)o.d=du/1000;o.paused=!!p.isPaused();\
    var m=p.getMovieId&&p.getMovieId();if(m)o.id=String(m);}}}}catch(e){}\
    var sl=null,mx=0;document.querySelectorAll('[role="slider"]').forEach(function(e){var x=+e.getAttribute('aria-valuemax');if(x>mx){mx=x;sl=e;}});\
    if(sl&&o.d==null&&mx>0){var now=+sl.getAttribute('aria-valuenow'),ms=mx>36000;o.d=ms?mx/1000:mx;o.p=ms?now/1000:now;}\
    var parts=[],t=document.querySelector('[data-uia="video-title"]');\
    if(t){t.querySelectorAll('h4,span').forEach(function(e){var x=(e.textContent||'').trim();if(x&&parts.indexOf(x)<0)parts.push(x);});if(!parts.length){var x=(t.textContent||'').trim();if(x)parts.push(x);}}\
    if(!parts.length&&sl){var bar=sl.parentElement&&sl.parentElement.parentElement;if(bar){var all=bar.querySelectorAll('*');for(var i=0;i<all.length&&parts.length<4;i++){var e=all[i];\
    if(e.children.length||e.closest('button'))continue;var x=(e.textContent||'').trim();if(x&&!/^-?[0-9]+(:[0-9]{2}){1,2}$/.test(x)&&parts.indexOf(x)<0)parts.push(x);}}}\
    var key=o.id||location.pathname;if(parts.length){c.parts=parts;c.key=key;}if(c.parts&&c.key===key)o.t=c.parts;\
    var v=null,a=0;document.querySelectorAll('video').forEach(function(x){var r=x.getBoundingClientRect(),q=r.width*r.height;if(q>a){a=q;v=x;}});\
    if(v){o.hasVideo=true;if(o.p==null&&isFinite(v.currentTime))o.p=v.currentTime;if(o.d==null&&isFinite(v.duration)&&v.duration>0)o.d=v.duration;if(o.paused==null)o.paused=v.paused;}\
    var md=navigator.mediaSession&&navigator.mediaSession.metadata;if(md){o.mt=md.title;o.ma=md.artist;var aw=md.artwork;if(aw&&aw.length)o.art=aw[aw.length-1].src;}\
    if(!o.art){var og=document.querySelector('meta[property="og:image"]');if(og)o.art=og.content;}o.dt=document.title;\
    var ae=document.activeElement;o.typing=!!(ae&&(/^(INPUT|TEXTAREA|SELECT)$/.test(ae.tagName)||ae.isContentEditable));\
    var mv=null,mq=0;document.querySelectorAll('video').forEach(function(x){var r=x.getBoundingClientRect(),q=r.width*r.height;\
    if(x.videoWidth>0&&!(isFinite(x.duration)&&x.duration<240)&&q>mq){mq=q;mv=x;}});if(mv){o.mvr=mv.readyState;o.mvp=mv.paused;}\
    o.login=!!document.querySelector('input[type=password]');o.gate=!!document.querySelector('[data-uia="profile-gate-screen"]');\
    try{var ui=netflix.reactContext.models.userInfo.data;if(ui&&ui.userGuid&&!o.gate)o.nfp=ui.userGuid;}catch(e){}\
    var hb=window.__hoverbirdCinema;if(hb&&hb.result)o.pic=hb.result;return JSON.stringify(o);})()
    """

    /// The picture mode for future page loads (the running page is updated by CinemaPicture).
    func pictureModeChanged() {
        guard let webView else { return }
        webView.configuration.userContentController.removeAllUserScripts()
        installPictureScript(in: webView)
    }

    /// Presses the player's "Skip Intro" / "Skip Recap" / "Next Episode" button.
    func skip() async -> String? {
        let js = """
        (function(){var re=/^(skip( intro| recap| credits| ad)?|next episode|watch next)/i,bad=/(back|forward|second|rewind)/i;\
        var l=document.querySelectorAll('button,[role=button],a');for(var i=0;i<l.length;i++){var b=l[i];\
        var t=((b.getAttribute('aria-label')||'')+' '+(b.innerText||'')).trim();var r=b.getBoundingClientRect();\
        if(r.width>0&&r.height>0&&re.test(t)&&!bad.test(t)){b.click();return t.slice(0,40);}}return '';})()
        """
        let label = await evaluate(js)
        return label.isEmpty || label.hasPrefix("error") ? nil : label
    }

    // MARK: Internals

    private func load(_ url: URL, in web: WKWebView) {
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
    }

    private func installPictureScript(in web: WKWebView) {
        let source = CinemaPicture.pageScript(mode: Defaults[.cinemaPictureMode], zoom: Defaults[.cinemaZoom])
        web.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    private func show() {
        guard let window else { return }
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
        window.level = Self.theaterLevel
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        showLeaveButton(for: 4)
    }

    /// "Leave Theater · esc" beside the notch, for a few seconds.
    func showLeaveButton(for seconds: Double = 3) {
        guard isOpen, let leaveButton, let screen = window?.screen ?? NSScreen.main else { return }
        leaveButton.show(on: screen, seconds: seconds)
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            let character = event.charactersIgnoringModifiers?.lowercased()
            let windowNumber = event.windowNumber
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, let window = self.window, self.routesKeys(windowNumber: windowNumber, theater: window) else { return false }
                // A: the next picture mode, like VLC (only while a video is on and you aren't typing).
                if plain, character == "a", self.pageHasVideo, !self.pageTyping {
                    CinemaPicture.shared.setMode(Defaults[.cinemaPictureMode].next)
                    return true
                }
                return self.handleKey(code, command: command)
            }
            return handled ? nil : event
        }
        // Esc from anywhere: macOS can hand the keyboard to another app while the Theater still
        // covers the screen — then your Esc went to an app you couldn't see and you were stuck.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                let theater = CinemaTheater.shared
                if theater.isOpen, theater.isInFront() { theater.close() }
            }
        }
        // While another app has the keyboard, macOS hands clicks in the top strip to that app's
        // menu bar (even under the Theater): catch a click on Leave Theater there too.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                let theater = CinemaTheater.shared
                guard theater.isOpen, let window = theater.window, let button = theater.leaveButton, button.alphaValue > 0.05 else { return }
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                if rect.contains(location), theater.isInFront() { theater.close() }
            }
        }
        // Back in Hoverbird (⌘Tab, Mission Control): over the whole screen again.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let theater = CinemaTheater.shared
                guard theater.isOpen else { return }
                theater.window?.level = Self.theaterLevel
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            }
        }
        // Another app came forward: let its windows cover the Theater like any window — but only
        // when it really shows a window over it (apps can become active without showing anything).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    let theater = CinemaTheater.shared
                    guard theater.isOpen, !NSApp.isActive, !theater.isInFront(ignoringLevel: true) else { return }
                    theater.window?.level = .normal
                }
            }
        }
    }

    /// Theater keys; everything else goes on to the player.
    private func handleKey(_ code: UInt16, command: Bool) -> Bool {
        switch (code, command) {
        case (53, false):
            // Esc leaves. Only while you type in a text field (a sign-in form) does the first Esc
            // just leave the field — and a second Esc within 2 s always leaves the Theater. Sliders,
            // buttons and players that hold the focus never keep you in, and neither does a page
            // that doesn't answer.
            let now = Date()
            if now.timeIntervalSince(lastEscape) < 2 { close(); return true }
            lastEscape = now
            Task { @MainActor in
                let typing = await evaluateQuickly(Self.leaveTextFieldScript, timeout: 0.6)
                if typing != "typing" { close() }
            }
        case (13, true): close()              // ⌘W
        case (33, true): webView?.goBack()    // ⌘[
        case (30, true): webView?.goForward() // ⌘]
        case (15, true): webView?.reload()    // ⌘R
        default: return false
        }
        return true
    }

    /// The Theater is what you see: no other app's window covers much of it. `ignoringLevel` asks
    /// whether one would, if the Theater were an ordinary window (windows "below" it count too).
    func isInFront(ignoringLevel: Bool = false) -> Bool {
        guard let window, window.isVisible else { return false }
        let ownPID = getpid()
        let screenRect = window.frame
        let main = NSScreen.screens.first?.frame.height ?? screenRect.height
        // CoreGraphics' top-left coordinates for the Theater.
        let theaterRect = CGRect(x: screenRect.minX, y: main - screenRect.maxY, width: screenRect.width, height: screenRect.height)
        let option: CGWindowListOption = ignoringLevel ? [.optionOnScreenOnly] : [.optionOnScreenAboveWindow]
        let relative = ignoringLevel ? kCGNullWindowID : CGWindowID(window.windowNumber)
        let list = CGWindowListCopyWindowInfo(option, relative) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            let overlap = rect.intersection(theaterRect)
            if !overlap.isNull, overlap.width * overlap.height > theaterRect.width * theaterRect.height * 0.15 {
                if ignoringLevel {
                    // Only windows of the app that is now active matter (others stay behind).
                    if let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier { return false }
                } else {
                    return false
                }
            }
        }
        return true
    }

    /// Keys meant for the Theater: its own window, the island above it (you just used the island),
    /// or no window at all — never another Hoverbird window you're typing in.
    private func routesKeys(windowNumber: Int, theater: NSWindow) -> Bool {
        if windowNumber == theater.windowNumber || windowNumber == 0 { return true }
        guard let other = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) else { return false }
        return other.level.rawValue > Self.theaterLevel.rawValue && !(other.firstResponder is NSTextView)
    }

    /// A text field in the page has the focus → leave the field, say "typing". Sliders, buttons and
    /// checkboxes (players keep the focus on those) don't count.
    private static let leaveTextFieldScript = """
    (function(){var a=document.activeElement;if(!a)return '';var t=(a.type||'').toLowerCase();\
    var text=a.isContentEditable||a.tagName==='TEXTAREA'||(a.tagName==='INPUT'&&['','text','email','password','search','tel','url','number'].indexOf(t)>=0);\
    if(text){a.blur();return 'typing';}return '';})()
    """

    /// The page's answer — or "" if it doesn't answer within `timeout` (a busy page never traps you).
    private func evaluateQuickly(_ js: String, timeout: Double) async -> String {
        guard let webView else { return "" }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            webView.evaluateJavaScript(js) { value, _ in once.resume((value as? String) ?? "") }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume("") }
        }
    }

    /// The built-in display (the one with the notch), else the one under the pointer.
    private static func targetScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// "amzn1.dv.gti.…" from the Prime Video app → primevideo.com/detail/…?autoplay=1&t=2145
    static func appTitleURL(bundleID: String, contentID: String?, position: TimeInterval) -> URL? {
        guard bundleID.lowercased().contains("com.amazon.aiv") || bundleID.lowercased().contains("primevideo"),
              let gti = contentID, gti.hasPrefix("amzn1.dv.gti."),
              gti.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        var components = URLComponents(string: "https://www.primevideo.com/detail/\(gti)/")
        components?.queryItems = [URLQueryItem(name: "autoplay", value: "1"),
                                  URLQueryItem(name: "t", value: String(Int(max(0, position))))]
        return components?.url
    }

    static func platform(for url: URL) -> OTTPlatform {
        if let platform = OTTDetector.platform(inText: url.absoluteString) { return platform }
        return OTTPlatform(name: url.host ?? "Theater", tint: .white)
    }

    /// Streaming sites only serve browsers they know: present as this Mac's Safari.
    nonisolated static let safariUserAgent: String = {
        let version = (Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    /// Signs out of every site opened in the Theater.
    static func removeWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

extension CinemaTheater: WKNavigationDelegate, WKUIDelegate {
    /// WebKit asks for the key that protects what pages keep in their databases (see
    /// TheaterCryptoKey). Answering here keeps WebKit away from the Keychain.
    @objc(_webCryptoMasterKeyForWebView:completionHandler:)
    nonisolated func webCryptoMasterKey(_ webView: WKWebView, completionHandler: @escaping (Data?) -> Void) {
        completionHandler(TheaterCryptoKey.key)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if let url = webView.url, url.scheme?.hasPrefix("http") == true { platform = Self.platform(for: url) }
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { _ = webView.reload() }
    }

    /// Links that open a new window (sign-in pages…) stay in the Theater.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        }
        return nil
    }
}

/// The note under the notch: "Smart — 3% trimmed per side, 8% taller · A changes it".
final class TheaterNote: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        alphaValue = 0
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows for `seconds`, centred, `belowTop` points under the top of the screen.
    func show(title: String, detail: String, belowTop: CGFloat, seconds: Double = 2.5) {
        guard let container = superview else { return }
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        let width = max(titleLabel.intrinsicContentSize.width, detailLabel.intrinsicContentSize.width) + 44
        let height: CGFloat = 56
        frame = NSRect(x: ((container.bounds.width - width) / 2).rounded(),
                       y: (container.bounds.height - belowTop - height).rounded(), width: width.rounded(), height: height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Keeps the Theater signed in. Many services sign you in with cookies that only last until the
/// browser quits unless "Keep me signed in" is ticked — Amazon does (Prime Video in India signs
/// in through amazon.in). WebKit dropped them whenever Hoverbird quit or updated, so the Theater
/// asked you to sign in again and Prime Video showed "Join Prime". While the Theater is open, the
/// streaming services' sign-in cookies are kept for 30 days (renewed as you use them); Settings ›
/// Cinema › Sign out of all removes them.
@MainActor
final class TheaterSignIns: NSObject, WKHTTPCookieStoreObserver {
    static let shared = TheaterSignIns()
    private var observing = false
    private var pending: Task<Void, Never>?

    func start() {
        guard !observing else { return }
        observing = true
        WKWebsiteDataStore.default().httpCookieStore.add(self)
        keepSoon()
    }

    /// The Theater closed: one last pass.
    func stop() {
        guard observing else { return }
        observing = false
        WKWebsiteDataStore.default().httpCookieStore.remove(self)
        keepSoon(after: 0)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        keepSoon()
    }

    private func keepSoon(after delay: Double = 1.5) {
        pending?.cancel()
        pending = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await Self.keep(in: WKWebsiteDataStore.default().httpCookieStore)
        }
    }

    /// Session cookies of streaming services (and Amazon's sign-in) → kept for 30 days.
    static func keep(in store: WKHTTPCookieStore) async {
        let until = Date().addingTimeInterval(30 * 24 * 3600)
        for cookie in await store.allCookies() where cookie.expiresDate == nil && isServiceDomain(cookie.domain) {
            guard var properties = cookie.properties else { continue }
            properties[.expires] = until
            properties[.discard] = nil
            properties[.maximumAge] = nil
            if let kept = HTTPCookie(properties: properties) { await store.setCookie(kept) }
        }
    }

    static func isServiceDomain(_ raw: String) -> Bool {
        let host = (raw.hasPrefix(".") ? String(raw.dropFirst()) : raw).lowercased()
        // Amazon's own sign-in (amazon.in, amazon.com, amazon.co.uk…) is Prime Video's.
        if host.range(of: "(^|\\.)amazon\\.[a-z]{2,3}(\\.[a-z]{2})?$", options: .regularExpression) != nil { return true }
        return OTTDetector.serviceDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Resumes a continuation once (whichever of the page's answer and the timeout comes first).
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func resume(_ value: String) {
        // Both callers run on the main thread.
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The Theater's content view: tells the Theater when the pointer moves (to show the way out).
final class TheaterContainer: NSView {
    var onMouseMove: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMove?()
        super.mouseMoved(with: event)
    }
}

/// "✕ Leave Theater  esc" in the top-left corner (in the strip beside the notch) — clear of the
/// island's window, which covers the area around the notch above the Theater.
final class TheaterLeaveButton: NSVisualEffectView {
    var onClick: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 168, height: 26))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        alphaValue = 0
        let icon = NSImageView(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        icon.contentTintColor = .white
        let title = NSTextField(labelWithString: "Leave Theater")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        let key = NSTextField(labelWithString: "esc")
        key.font = .systemFont(ofSize: 10, weight: .semibold)
        key.textColor = NSColor.white.withAlphaComponent(0.6)
        let stack = NSStackView(views: [icon, title, key])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Leave Theater")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    /// Works on the first click even when another app has the keyboard.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    /// The whole capsule is the button; invisible → clicks go to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue > 0.05 && frame.contains(point) ? self : nil }

    func show(on screen: NSScreen, seconds: Double) {
        guard let container = superview else { return }
        // Top-left, centred in the strip beside the notch (16 pt from the top without a notch).
        let strip = screen.safeAreaInsets.top
        let y = strip > 0 ? container.bounds.height - strip / 2 - frame.height / 2 : container.bounds.height - 16 - frame.height
        frame.origin = NSPoint(x: 16, y: y.rounded())
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                animator().alphaValue = 1
            }
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
