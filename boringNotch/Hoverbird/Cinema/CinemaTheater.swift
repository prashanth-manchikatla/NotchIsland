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
//  Keys: Esc or ⌘W leave · ⌘[ back · ⌘] forward · ⌘R reload. Everything else goes to the
//  player (space, ← →, F, M…).
//

import AppKit
import Combine
import Defaults
import WebKit

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
    private var keyMonitor: Any?
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
        let id = MusicManager.shared.bundleIdentifier ?? ""
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
        let fallback = OTTDetector.homeURL(forPlatformNamed: LiveVideoManager.shared.ottPlatform?.name)
        if MusicManager.shared.isPlaying { MusicManager.shared.pause() }
        Task.detached(priority: .userInitiated) {
            // Browsers and web apps show the page's address through Accessibility.
            let url = pid.flatMap { CinemaPicture.webAreaURL(pid: $0) } ?? fallback
            await MainActor.run {
                guard let url else { return }
                CinemaTheater.shared.open(url: url)
            }
        }
    }

    func open(url: URL) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        platform = Self.platform(for: url)
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
        window.contentView = web
        self.window = window
        webView = web
        isOpen = true
        load(url, in: web)
        installMonitors()
        show()
    }

    func close() {
        guard isOpen else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        activeObserver = nil
        resignObserver = nil
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
        NSApp.activate(ignoringOtherApps: true)
        window.level = Self.theaterLevel
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let windowNumber = event.windowNumber
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, let window = self.window, window.windowNumber == windowNumber else { return false }
                return self.handleKey(code, command: command)
            }
            return handled ? nil : event
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
        // Another app came forward: let its windows cover the Theater like any window.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                CinemaTheater.shared.window?.level = .normal
            }
        }
    }

    /// Theater keys; everything else goes on to the player.
    private func handleKey(_ code: UInt16, command: Bool) -> Bool {
        switch (code, command) {
        case (53, false): // Esc: leave, unless you're typing (then just stop typing)
            Task { @MainActor in
                let editing = await evaluate("(function(){var a=document.activeElement;if(a&&(/INPUT|TEXTAREA|SELECT/.test(a.tagName)||a.isContentEditable)){a.blur();return 'editing';}return '';})()")
                if editing != "editing" { close() }
            }
        case (13, true): close()              // ⌘W
        case (33, true): webView?.goBack()    // ⌘[
        case (30, true): webView?.goForward() // ⌘]
        case (15, true): webView?.reload()    // ⌘R
        default: return false
        }
        return true
    }

    /// The built-in display (the one with the notch), else the one under the pointer.
    private static func targetScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func platform(for url: URL) -> OTTPlatform {
        if let platform = OTTDetector.platform(inText: url.absoluteString) { return platform }
        return OTTPlatform(name: url.host ?? "Theater", tint: .white)
    }

    /// Streaming sites only serve browsers they know: present as this Mac's Safari.
    private static let safariUserAgent: String = {
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
