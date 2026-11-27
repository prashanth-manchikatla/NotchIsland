//
//  CinemaNowPlaying.swift
//  Hoverbird
//
//  What a streaming page knows about what's playing — title, episode, picture and time —
//  for the island's player. Netflix tells macOS Now Playing only "Netflix", its site icon
//  and no time at all, so the island had nothing to show. Now:
//
//   • Netflix in its web app or a browser tab: the player's own controls (title, episode, and
//     the seek bar's exact position and length) are read through Accessibility whenever they
//     are on screen — when playback starts and whenever the pointer moves, e.g. on its way to
//     the notch. From there the time keeps counting, following play / pause; ±10 s from the
//     island moves it too.
//   • The Theater (Hoverbird's own window): read straight from the page, every second.
//   • The picture: the title's public page on netflix.com names its key art. Only that page's
//     first few KB are read — without cookies, so nothing about you is sent — and the image is
//     downloaded once and kept small.
//
//  It only fills gaps: whatever the service tells macOS itself is kept.
//

import AppKit
import Combine
import Defaults
import ImageIO
import UniformTypeIdentifiers

/// What the page shows about what's playing.
struct CinemaPageInfo: Equatable {
    /// The app playing it: a browser, a Safari web app, or Hoverbird itself (the Theater).
    var source: String
    /// Netflix's id of the movie or episode (from the address).
    var videoID: String?
    /// Which picture belongs to it (the Netflix id, or "url:…" for other sites).
    var artworkKey: String?
    var title: String?
    /// "E3 · The Case of the Missing Lifeguard"
    var subtitle: String?
    var duration: Double?
}

@MainActor
final class CinemaNowPlaying {
    static let shared = CinemaNowPlaying()

    struct TitlePage {
        var name: String?
        var artwork: Data?
        var date = Date()
    }

    private(set) var page: CinemaPageInfo?
    /// The position clock: where it was, when, and whether it has been moving since.
    private var anchor: (position: Double, date: Date, playing: Bool)?
    /// Key art (and names) by Netflix id or image address.
    private var pictures: [String: TitlePage] = [:]
    private var fetching: Set<String> = []
    private var readerTask: Task<Void, Never>?
    private var readerSource: String?
    private var viewing = false
    private var iconCheck: (count: Int, isIcon: Bool)?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let music = MusicManager.shared
        let sources: [AnyPublisher<Void, Never>] = [
            music.$bundleIdentifier.map { _ in () }.eraseToAnyPublisher(),
            music.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            LiveVideoManager.shared.$ottPlatform.map { _ in () }.eraseToAnyPublisher(),
            CinemaTheater.shared.$isOpen.map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.cinemaModeEnabled).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.evaluate() }
            .store(in: &cancellables)
    }

    /// Called at launch so the subscriptions exist before the first video.
    func start() {}

    // MARK: Filling in Now Playing

    /// Every Now Playing update passes through here (MusicManager): fills in what the
    /// service left out with what its page shows.
    func enrich(_ raw: PlaybackState) -> PlaybackState {
        guard Defaults[.cinemaModeEnabled], let page, page.source == raw.bundleIdentifier else { return raw }
        var state = raw
        let generic = isGeneric(raw.title, source: raw.bundleIdentifier)
        let picture = page.artworkKey.flatMap { pictures[$0] }
        if generic, let title = page.title ?? picture?.name {
            state.title = title
        } else if !generic {
            state.title = OTTDetector.withoutServiceName(raw.title) // "Prime Video: Jumanji" → "Jumanji"
        }
        if generic || raw.artist.isEmpty {
            state.artist = page.subtitle ?? (generic ? "" : raw.artist)
        }
        // The site icon isn't a picture of the show: use the key art, or the platform tile.
        if let art = picture?.artwork, raw.artwork == nil || isSiteIcon(raw.artwork) {
            state.artwork = art
        } else if isSiteIcon(raw.artwork) {
            state.artwork = nil
        }
        if raw.duration <= 0, let duration = page.duration, duration > 0, anchor != nil {
            let now = Date()
            // Keep the clock in step with play / pause from Now Playing.
            if let a = anchor, a.playing != raw.isPlaying {
                anchor = (clockPosition(at: now) ?? a.position, now, raw.isPlaying)
            }
            state.duration = duration
            state.currentTime = clockPosition(at: now) ?? 0
            state.lastUpdated = now
            state.playbackRate = 1
        }
        return state
    }

    /// Lyrics are looked up on the web by title: never for movies and shows.
    func suppressesLyrics(for bundleID: String) -> Bool {
        if bundleID == Bundle.main.bundleIdentifier || page?.source == bundleID { return true }
        if LiveVideoManager.shared.ottPlatform != nil, MusicManager.shared.bundleIdentifier == bundleID { return true }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        return OTTDetector.platform(forApp: bundleID, appName: name) != nil
    }

    /// The island's ±10 s: move the clock right away (the page confirms on its next read).
    func seeked(by delta: Double) {
        guard let a = anchor else { return }
        let now = Date()
        var position = (clockPosition(at: now) ?? a.position) + delta
        if let duration = page?.duration { position = min(position, duration) }
        anchor = (max(0, position), now, a.playing)
        MusicManager.shared.reapplyLastState()
    }

    /// The Netflix title this app is playing, at your second (for moving it into the Theater).
    func netflixWatchURL(for source: String, position: TimeInterval) -> URL? {
        guard let page, page.source == source, page.artworkKey == page.videoID,
              let id = page.videoID, !id.isEmpty, id.allSatisfy(\.isNumber),
              let url = URL(string: "https://www.netflix.com/watch/\(id)") else { return nil }
        return CinemaTheater.startingAt(url, seconds: position)
    }

    /// The island is open on the player: read more often so it's up to date.
    func setViewing(_ on: Bool) {
        viewing = on
        if on, let source = readerSource {
            readerSource = nil
            startReader(source: source) // reads right away
        }
    }

    // MARK: Sources

    private func evaluate() {
        let music = MusicManager.shared
        let id = music.bundleIdentifier ?? ""
        let own = Bundle.main.bundleIdentifier ?? ""
        if let page, page.source != id {
            self.page = nil
            anchor = nil
        }
        let netflixWeb = LiveVideoManager.shared.ottPlatform?.name == "Netflix"
            && !id.isEmpty && id != own
            && (OTTDetector.isBrowser(id) || id.hasPrefix("com.apple.Safari.WebApp"))
        if netflixWeb, music.hasActiveMedia, Defaults[.cinemaModeEnabled], AXIsProcessTrusted() {
            startReader(source: id)
        } else {
            stopReader()
        }
    }

    private func startReader(source: String) {
        guard readerSource != source || readerTask == nil else { return }
        stopReader()
        readerSource = source
        readerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: source).first?.processIdentifier else { return }
                let snapshot = await Task.detached(priority: .utility) { NetflixPageReader.read(pid: pid) }.value
                guard !Task.isCancelled, let self else { return }
                if let snapshot { self.absorb(snapshot, source: source) }
                // Quick while you look at the island; while playing, quick until the time is known
                // (Netflix shows its controls for ~3 s), then slow. A read costs a few ms.
                let interval: Double
                if self.viewing { interval = 1.5 }
                else if !MusicManager.shared.isPlaying { interval = 20 }
                else { interval = self.anchor == nil ? 2.5 : 8 }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopReader() {
        readerTask?.cancel()
        readerTask = nil
        readerSource = nil
    }

    /// Netflix in a browser or its web app (read through Accessibility).
    private func absorb(_ snapshot: NetflixPageReader.Snapshot, source: String) {
        var info = (page?.source == source ? page : nil) ?? CinemaPageInfo(source: source)
        if let id = snapshot.videoID, id != info.videoID {
            info = CinemaPageInfo(source: source, videoID: id, artworkKey: id) // a new title or the next episode
            anchor = nil
            fetchNetflixTitle(id)
        }
        if !snapshot.titleParts.isEmpty {
            info.title = snapshot.titleParts[0]
            info.subtitle = snapshot.titleParts.count > 1 ? snapshot.titleParts.dropFirst().joined(separator: " · ") : nil
        }
        var synced = false
        if let duration = snapshot.duration { info.duration = duration }
        if let position = snapshot.position {
            anchor = (position, snapshot.date, MusicManager.shared.isPlaying)
            synced = true
        }
        let changed = info != page
        page = info
        if changed || synced { MusicManager.shared.reapplyLastState() }
    }

    /// The Theater's page (its JSON from CinemaTheater's page check).
    func theaterPage(_ json: [String: Any]) {
        let own = Bundle.main.bundleIdentifier ?? ""
        var info = (page?.source == own ? page : nil) ?? CinemaPageInfo(source: own)
        let url = (json["u"] as? String).flatMap(URL.init(string:))
        let isNetflix = url?.host?.hasSuffix("netflix.com") == true
        var id = (json["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if id == nil, isNetflix, let url { id = NetflixPageReader.videoID(in: url) }
        let pageKey = id ?? url.map { ($0.host ?? "") + $0.path }
        if pageKey != info.videoID {
            info = CinemaPageInfo(source: own, videoID: pageKey)
            anchor = nil
            if isNetflix, let id {
                info.artworkKey = id
                fetchNetflixTitle(id)
            }
        }
        if let parts = json["t"] as? [String], let first = parts.first, !first.isEmpty {
            info.title = first
            info.subtitle = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
        } else if let title = json["mt"] as? String, !title.isEmpty {
            info.title = OTTDetector.withoutServiceName(title)
            info.subtitle = (json["ma"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } else if !isNetflix, let title = json["dt"] as? String, !title.isEmpty, !OTTDetector.isServiceName(title) {
            info.title = OTTDetector.withoutServiceName(title)
        }
        if !isNetflix, let art = json["art"] as? String, let artURL = URL(string: art), artURL.scheme == "https" {
            info.artworkKey = "url:" + art
            fetchImage(artURL, key: "url:" + art)
        }
        if let duration = json["d"] as? Double, duration.isFinite, duration >= 30 { info.duration = duration }
        if let position = json["p"] as? Double, position.isFinite {
            anchor = (max(0, position), Date(), !((json["paused"] as? Bool) ?? false))
        }
        page = info
        MusicManager.shared.reapplyLastState()
    }

    func theaterClosed() {
        if page?.source == Bundle.main.bundleIdentifier {
            page = nil
            anchor = nil
        }
    }

    // MARK: Helpers

    private func clockPosition(at date: Date) -> Double? {
        guard let a = anchor else { return nil }
        var position = a.position + (a.playing ? max(0, date.timeIntervalSince(a.date)) : 0)
        if let duration = page?.duration { position = min(position, duration) }
        return max(0, position)
    }

    /// "Netflix", "Prime Video", the web app's own name: not the name of a show.
    private func isGeneric(_ title: String, source: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty || OTTDetector.isServiceName(t) { return true }
        if let name = LiveVideoManager.shared.ottPlatform?.name.lowercased(), t == name { return true }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: source).first?.localizedName?.lowercased()
        return t == app
    }

    /// A site icon (Netflix sends a 64 × 64 favicon as "artwork").
    private func isSiteIcon(_ data: Data?) -> Bool {
        guard let data else { return false }
        if let check = iconCheck, check.count == data.count { return check.isIcon }
        var icon = false
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            icon = max(width, height) <= 128
        }
        iconCheck = (data.count, icon)
        return icon
    }

    private func fetchNetflixTitle(_ id: String) {
        if let known = pictures[id], known.artwork != nil || Date().timeIntervalSince(known.date) < 600 { return }
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        Task { @MainActor [weak self] in
            let result = await NetflixTitlePage.load(id: id)
            guard let self else { return }
            self.fetching.remove(id)
            self.remember(result ?? TitlePage(), for: id)
        }
    }

    private func fetchImage(_ url: URL, key: String) {
        if let known = pictures[key], known.artwork != nil || Date().timeIntervalSince(known.date) < 600 { return }
        guard !fetching.contains(key) else { return }
        fetching.insert(key)
        Task { @MainActor [weak self] in
            let data = await CinemaArtwork.download(url)
            guard let self else { return }
            self.fetching.remove(key)
            self.remember(TitlePage(name: nil, artwork: data), for: key)
        }
    }

    private func remember(_ picture: TitlePage, for key: String) {
        pictures[key] = picture
        if pictures.count > 40, let oldest = pictures.min(by: { $0.value.date < $1.value.date })?.key {
            pictures[oldest] = nil
        }
        if page?.artworkKey == key { MusicManager.shared.reapplyLastState() }
    }
}

// MARK: - Netflix's player, read through Accessibility

enum NetflixPageReader {
    struct Snapshot: Sendable {
        var videoID: String?
        /// ["Stranger Things", "E3", "The Case of the Missing Lifeguard"] / ["A Movie"]
        var titleParts: [String] = []
        var position: Double?
        var duration: Double?
        var date = Date()
    }

    /// "https://www.netflix.com/watch/80077209?trackId=…" → "80077209"
    nonisolated static func videoID(in url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "watch"), index + 1 < parts.count else { return nil }
        let id = parts[index + 1]
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }

    /// Off the main thread. Netflix's seek bar and title are only in the page while its
    /// controls show; otherwise this returns just the title id.
    nonisolated static func read(pid: pid_t) -> Snapshot? {
        // Never our own process: WebKit's views may only be read on the main thread.
        guard AXIsProcessTrusted(), pid != getpid() else { return nil }
        let app = AX.app(pid: pid)
        var windows: [AXUIElement] = []
        for name in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let value = AX.attribute(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                windows.append(value as! AXUIElement)
            }
        }
        for window in AX.elements(app, kAXWindowsAttribute as String) where !windows.contains(where: { CFEqual($0, window) }) {
            windows.append(window)
        }
        let deadline = Date().addingTimeInterval(0.8)
        for window in windows.prefix(8) {
            guard let (area, url) = playerArea(in: window, deadline: deadline) else { continue }
            return readPlayer(area, url: url, deadline: deadline)
        }
        return nil
    }

    /// The web page showing netflix.com/watch/… in this window.
    nonisolated private static func playerArea(in window: AXUIElement, deadline: Date) -> (AXUIElement, URL)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < 120, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            if AX.role(element) == "AXWebArea" {
                var url: URL?
                if let value = AX.attribute(element, "AXURL") {
                    url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                }
                if let url, url.host?.hasSuffix("netflix.com") == true, videoID(in: url) != nil { return (element, url) }
                continue
            }
            if depth < 8 { queue += AX.children(element).map { ($0, depth + 1) } }
        }
        return nil
    }

    nonisolated private static func readPlayer(_ area: AXUIElement, url: URL, deadline: Date) -> Snapshot {
        var snapshot = Snapshot(videoID: videoID(in: url))
        var texts: [(String, [AXUIElement])] = []
        var sliders: [(value: Double, max: Double, desc: String?, path: [AXUIElement])] = []
        var visited = 0
        func walk(_ element: AXUIElement, _ path: [AXUIElement]) {
            guard visited < 600, Date() < deadline else { return }
            visited += 1
            switch AX.role(element) ?? "" {
            case "AXStaticText":
                if let value = AX.string(element, kAXValueAttribute as String) { texts.append((value, path)) }
                return
            case "AXSlider":
                if let value = number(AX.attribute(element, kAXValueAttribute as String)),
                   let max = number(AX.attribute(element, kAXMaxValueAttribute as String)), max > 0 {
                    sliders.append((value, max, AX.string(element, "AXValueDescription"), path))
                }
                return
            case "AXButton", "AXImage", "AXLink", "AXTextField":
                return
            case "AXGroup":
                // Subtitles aren't titles.
                if let classes = AX.attribute(element, "AXDOMClassList") as? [String],
                   classes.contains(where: { $0.hasPrefix("player-timedtext") }) { return }
            default:
                break
            }
            let next = path + [element]
            for child in AX.children(element) { walk(child, next) }
        }
        walk(area, [])
        snapshot.date = Date()

        // The seek bar: the slider with the longest range (the volume slider is short).
        guard let seek = sliders.max(by: { $0.max < $1.max }) else { return snapshot }
        let (position, duration) = seconds(value: seek.value, max: seek.max, desc: seek.desc)
        if duration >= 30, duration <= 36_000 {
            snapshot.duration = duration
            snapshot.position = min(max(0, position), duration)
        }
        // The title sits in the same control bar as the seek bar (the bar holds the seek row).
        if seek.path.count >= 2 {
            let bar = seek.path[seek.path.count - 2]
            for (text, path) in texts where path.contains(where: { CFEqual($0, bar) }) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !isTime(t), !snapshot.titleParts.contains(t), snapshot.titleParts.count < 4 else { continue }
                snapshot.titleParts.append(t)
            }
        }
        return snapshot
    }

    nonisolated private static func number(_ value: CFTypeRef?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Netflix's seek bar counts milliseconds ("4667676", described as "4667 of 8712").
    nonisolated static func seconds(value: Double, max: Double, desc: String?) -> (Double, Double) {
        if let desc {
            let numbers = desc.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
            if numbers.count >= 2 {
                if abs(numbers[1] - max / 1000) <= 2 { return (value / 1000, max / 1000) }
                if abs(numbers[1] - max) <= 2 { return (value, max) }
            }
        }
        return max > 36_000 ? (value / 1000, max / 1000) : (value, max)
    }

    /// "1:07:25", "42:10", "-3:05"
    nonisolated static func isTime(_ text: String) -> Bool {
        let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
        guard body.contains(":"), body.count <= 9 else { return false }
        return body.allSatisfy { $0.isNumber || $0 == ":" }
    }
}

// MARK: - Key art

enum NetflixTitlePage {
    /// No cookies, no cache on disk: the request carries nothing about you.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// The title's public page (an episode's id leads to its show) → name + key art.
    static func load(id: String) async -> CinemaNowPlaying.TitlePage? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber), let url = URL(string: "https://www.netflix.com/title/\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(CinemaTheater.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            // og:title and og:image are in the first few KB of a 1 MB page.
            var head = Data()
            head.reserveCapacity(32_768)
            for try await byte in bytes {
                head.append(byte)
                if head.count >= 65_536 { break }
                if head.count % 2048 == 0, let text = String(data: head, encoding: .utf8), text.contains("og:image") && text.contains("og:title") {
                    break
                }
            }
            guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
            let name = meta("og:title", in: text).map(cleanTitle)
            var artwork: Data?
            if let image = meta("og:image", in: text).flatMap(URL.init(string:)), isNetflixImage(image) {
                artwork = await CinemaArtwork.download(image)
            }
            return CinemaNowPlaying.TitlePage(name: name, artwork: artwork)
        } catch {
            return nil
        }
    }

    private static func isNetflixImage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return ["nflxso.net", "nflximg.net", "nflxext.com", "netflix.com"].contains { host.hasSuffix($0) }
    }

    /// <meta … property="og:image" content="…">
    private static func meta(_ property: String, in html: String) -> String? {
        for pattern in ["property=\"\(property)\"[^>]*?content=\"([^\"]+)\"", "content=\"([^\"]+)\"[^>]*?property=\"\(property)\""] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return decodeEntities(String(html[range]))
            }
        }
        return nil
    }

    /// "Watch Stranger Things | Netflix Official Site" → "Stranger Things"
    static func cleanTitle(_ raw: String) -> String {
        var name = raw
        if let bar = name.range(of: " | ") { name = String(name[..<bar.lowerBound]) }
        if name.hasPrefix("Watch ") { name.removeFirst(6) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}

enum CinemaArtwork {
    /// Downloads a picture and keeps it small (480 px on the long side, JPEG).
    static func download(_ url: URL) async -> Data? {
        guard url.scheme == "https",
              let (data, response) = try? await NetflixTitlePage.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000 else { return nil }
        return await Task.detached(priority: .utility) { shrink(data) }.value
    }

    nonisolated static func shrink(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
