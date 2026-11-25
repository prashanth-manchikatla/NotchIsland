//
//  OTTPlatform.swift
//  Hoverbird
//
//  Streaming services (Netflix, Prime Video, JioHotstar, Disney+, Apple TV…)
//  protect their video with DRM, so screen capture only ever sees a black
//  rectangle. Instead of mirroring a black box, the island recognises these
//  platforms and shows the show's info — title, episode, duration, platform —
//  with its artwork, exactly like the regular (non-video) player.
//

import AppKit
import SwiftUI

struct OTTPlatform: Equatable {
    let name: String
    let tint: Color
    /// Recognised only because its video captured as solid black (DRM).
    var detectedByBlackFrames = false
    /// A course / learning platform (Coursera, Udemy, 1% Club…).
    var isEducation = false

    static func == (lhs: OTTPlatform, rhs: OTTPlatform) -> Bool {
        lhs.name == rhs.name && lhs.detectedByBlackFrames == rhs.detectedByBlackFrames
    }
}

enum OTTDetector {
    private struct Rule {
        let name: String
        let tint: Color
        /// How the site names itself in page titles (lowercased): "… | Prime Video", "Netflix".
        let marks: [String]
        let domains: [String]
        /// Pieces of native-app bundle IDs (lowercased).
        let bundleHints: [String]
        var education = false

        var platform: OTTPlatform { OTTPlatform(name: name, tint: tint, isEducation: education) }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private static let rules: [Rule] = [
        Rule(name: "Netflix", tint: hex(0xE50914), marks: ["netflix"], domains: ["netflix.com"], bundleHints: ["netflix"]),
        Rule(name: "Prime Video", tint: hex(0x1A98FF), marks: ["prime video", "amazon prime video"],
             domains: ["primevideo.com", "amazon.com/gp/video", "amazon.in/gp/video", "amazon.co.uk/gp/video"],
             bundleHints: ["com.amazon.aiv", "primevideo"]),
        Rule(name: "JioHotstar", tint: hex(0x1F80E0), marks: ["jiohotstar", "disney+ hotstar", "hotstar"],
             domains: ["hotstar.com", "jiohotstar.com"], bundleHints: ["hotstar"]),
        Rule(name: "Disney+", tint: hex(0x2C5BFF), marks: ["disney+", "disney plus"], domains: ["disneyplus.com"],
             bundleHints: ["disneyplus", "com.disney."]),
        Rule(name: "JioCinema", tint: hex(0xD9008D), marks: ["jiocinema"], domains: ["jiocinema.com"],
             bundleHints: ["jiocinema", "com.jio.media"]),
        Rule(name: "SonyLIV", tint: hex(0xF5B301), marks: ["sonyliv", "sony liv"], domains: ["sonyliv.com"], bundleHints: ["sonyliv"]),
        Rule(name: "ZEE5", tint: hex(0x8230C6), marks: ["zee5"], domains: ["zee5.com"], bundleHints: ["zee5"]),
        Rule(name: "Apple TV", tint: .white, marks: ["apple tv+", "apple tv"], domains: ["tv.apple.com"], bundleHints: []),
        Rule(name: "Hulu", tint: hex(0x1CE783), marks: ["hulu"], domains: ["hulu.com"], bundleHints: ["hulu"]),
        Rule(name: "HBO Max", tint: hex(0x7B3FF2), marks: ["hbo max", "max"], domains: ["max.com", "hbomax.com"],
             bundleHints: ["hbo", "wbd.stream"]),
        Rule(name: "Paramount+", tint: hex(0x0064FF), marks: ["paramount+", "paramount plus"], domains: ["paramountplus.com"],
             bundleHints: ["cbsvideo", "paramount"]),
        Rule(name: "Peacock", tint: hex(0xFFC300), marks: ["peacock"], domains: ["peacocktv.com"], bundleHints: ["peacock"]),
        Rule(name: "Crunchyroll", tint: hex(0xF47521), marks: ["crunchyroll"], domains: ["crunchyroll.com"], bundleHints: ["crunchyroll"]),
        Rule(name: "aha", tint: hex(0xFF6D00), marks: ["aha"], domains: ["aha.video"], bundleHints: ["ahavideo"]),
        Rule(name: "Sun NXT", tint: hex(0xF15A24), marks: ["sun nxt", "sunnxt"], domains: ["sunnxt.com"], bundleHints: ["sunnxt"]),
        Rule(name: "MX Player", tint: hex(0x2C8DFF), marks: ["mx player"], domains: ["mxplayer.in"], bundleHints: ["mxplayer"]),
        Rule(name: "discovery+", tint: hex(0x2175D9), marks: ["discovery+", "discovery plus"],
             domains: ["discoveryplus.com", "discoveryplus.in"], bundleHints: ["discoveryplus"]),
        Rule(name: "MUBI", tint: .white, marks: ["mubi"], domains: ["mubi.com"], bundleHints: ["mubi"]),
        Rule(name: "YouTube TV", tint: hex(0xFF0033), marks: ["youtube tv"], domains: ["tv.youtube.com"], bundleHints: []),
        Rule(name: "Tubi", tint: hex(0xFA541C), marks: ["tubi"], domains: ["tubitv.com"], bundleHints: ["tubitv"]),
        Rule(name: "Rakuten Viki", tint: hex(0x1BA5E1), marks: ["rakuten viki", "viki"], domains: ["viki.com"], bundleHints: ["viki"]),
        Rule(name: "Starz", tint: .white, marks: ["starz"], domains: ["starz.com"], bundleHints: ["starz"]),
        Rule(name: "Sling TV", tint: hex(0x2E9BDB), marks: ["sling tv"], domains: ["sling.com"], bundleHints: []),
        Rule(name: "fuboTV", tint: hex(0xFA4616), marks: ["fubo", "fubotv"], domains: ["fubo.tv"], bundleHints: ["fubo"]),
        Rule(name: "Lionsgate Play", tint: hex(0xE4B33C), marks: ["lionsgate play"], domains: ["lionsgateplay.com"],
             bundleHints: ["lionsgateplay"]),
        Rule(name: "hoichoi", tint: hex(0xE6252A), marks: ["hoichoi"], domains: ["hoichoi.tv"], bundleHints: ["hoichoi"]),
        Rule(name: "Airtel Xstream", tint: hex(0xE40000), marks: ["airtel xstream", "xstream play"], domains: ["airtelxstream.in"],
             bundleHints: ["xstream"]),
        Rule(name: "Tata Play", tint: hex(0xE10070), marks: ["tata play", "tata play binge"], domains: ["tataplay.com"],
             bundleHints: ["tataplay"]),

        // Learning platforms: course videos are usually DRM-protected (or drawn by custom
        // players), so they get the info view too.
        Rule(name: "1% Club", tint: hex(0x1E88E5),
             marks: ["1%club", "1% club", "onepercentclub", "one percent club", "onepercent club", "1 percent club"],
             domains: ["onepercentclub.io", "onepercentclub.com", "onepercentclub.in"], bundleHints: ["onepercentclub"], education: true),
        Rule(name: "Coursera", tint: hex(0x2A73FF), marks: ["coursera"], domains: ["coursera.org"], bundleHints: ["coursera"], education: true),
        Rule(name: "Udemy", tint: hex(0xA435F0), marks: ["udemy", "udemy business"], domains: ["udemy.com"], bundleHints: ["udemy"], education: true),
        Rule(name: "LinkedIn Learning", tint: hex(0x2E8BEF), marks: ["linkedin learning"], domains: ["linkedin.com/learning"],
             bundleHints: [], education: true),
        Rule(name: "Skillshare", tint: hex(0x00C36B), marks: ["skillshare"], domains: ["skillshare.com"], bundleHints: ["skillshare"], education: true),
        Rule(name: "MasterClass", tint: hex(0xE32652), marks: ["masterclass"], domains: ["masterclass.com"], bundleHints: ["masterclass"], education: true),
        Rule(name: "edX", tint: hex(0x1FA2B8), marks: ["edx"], domains: ["edx.org"], bundleHints: ["edx"], education: true),
        Rule(name: "Khan Academy", tint: hex(0x14BF96), marks: ["khan academy"], domains: ["khanacademy.org"], bundleHints: ["khanacademy"], education: true),
        Rule(name: "Pluralsight", tint: hex(0xF15B2A), marks: ["pluralsight"], domains: ["pluralsight.com"], bundleHints: ["pluralsight"], education: true),
        Rule(name: "Udacity", tint: hex(0x02B3E4), marks: ["udacity"], domains: ["udacity.com"], bundleHints: ["udacity"], education: true),
        Rule(name: "Domestika", tint: hex(0xE8433B), marks: ["domestika"], domains: ["domestika.org"], bundleHints: ["domestika"], education: true),
        Rule(name: "DataCamp", tint: hex(0x03EF62), marks: ["datacamp"], domains: ["datacamp.com"], bundleHints: ["datacamp"], education: true),
        Rule(name: "Codecademy", tint: hex(0x7B61FF), marks: ["codecademy"], domains: ["codecademy.com"], bundleHints: ["codecademy"], education: true),
        Rule(name: "O’Reilly", tint: hex(0xE0123F), marks: ["o'reilly", "o’reilly", "o'reilly media", "o’reilly media", "oreilly"],
             domains: ["learning.oreilly.com", "oreilly.com"], bundleHints: ["oreilly"], education: true),
        Rule(name: "Frontend Masters", tint: hex(0xE0473F), marks: ["frontend masters"], domains: ["frontendmasters.com"],
             bundleHints: ["frontendmasters"], education: true),
        Rule(name: "egghead", tint: hex(0xF4A84B), marks: ["egghead", "egghead.io"], domains: ["egghead.io"], bundleHints: [], education: true),
        Rule(name: "Educative", tint: hex(0x6E6CFF), marks: ["educative"], domains: ["educative.io"], bundleHints: ["educative"], education: true),
        Rule(name: "Brilliant", tint: hex(0x48A868), marks: ["brilliant"], domains: ["brilliant.org"], bundleHints: ["brilliant"], education: true),
        Rule(name: "KodeKloud", tint: hex(0x3D7BFF), marks: ["kodekloud"], domains: ["kodekloud.com"], bundleHints: ["kodekloud"], education: true),
        Rule(name: "Zero To Mastery", tint: hex(0x3B82F6), marks: ["zero to mastery"], domains: ["zerotomastery.io"], bundleHints: [], education: true),
        Rule(name: "Treehouse", tint: hex(0x5FCF80), marks: ["treehouse"], domains: ["teamtreehouse.com"], bundleHints: [], education: true),
        Rule(name: "Unacademy", tint: hex(0x08BD80), marks: ["unacademy"], domains: ["unacademy.com"], bundleHints: ["unacademy"], education: true),
        Rule(name: "BYJU’S", tint: hex(0x9B59D0), marks: ["byju's", "byju’s", "byjus"], domains: ["byjus.com"], bundleHints: ["byjus"], education: true),
        Rule(name: "Physics Wallah", tint: hex(0x7B6CF0), marks: ["physics wallah", "physicswallah", "pw live"],
             domains: ["pw.live", "physicswallah.live", "physicswallah.com"], bundleHints: ["physicswallah", "physicswala", "penpencil"], education: true),
        Rule(name: "Vedantu", tint: hex(0xF3754E), marks: ["vedantu"], domains: ["vedantu.com"], bundleHints: ["vedantu"], education: true),
        Rule(name: "upGrad", tint: hex(0xE8303C), marks: ["upgrad"], domains: ["upgrad.com"], bundleHints: ["upgrad"], education: true),
        Rule(name: "Simplilearn", tint: hex(0xFF8C1A), marks: ["simplilearn"], domains: ["simplilearn.com"], bundleHints: ["simplilearn"], education: true),
        Rule(name: "Great Learning", tint: hex(0x2F8CF0), marks: ["great learning", "mygreatlearning"],
             domains: ["mygreatlearning.com", "greatlearning.in"], bundleHints: ["greatlearning"], education: true),
        Rule(name: "Scaler", tint: hex(0x3B7BF5), marks: ["scaler", "scaler academy"], domains: ["scaler.com"], bundleHints: ["scaler"], education: true),
        Rule(name: "Testbook", tint: hex(0x2AA7FF), marks: ["testbook"], domains: ["testbook.com"], bundleHints: ["testbook"], education: true),
        Rule(name: "Adda247", tint: hex(0xE8383E), marks: ["adda247"], domains: ["adda247.com"], bundleHints: ["adda247"], education: true),
        Rule(name: "Seekho", tint: hex(0xFF7A00), marks: ["seekho"], domains: ["seekho.ai", "seekho.in"], bundleHints: ["seekho"], education: true),
        Rule(name: "Newton School", tint: hex(0x3B82F6), marks: ["newton school"], domains: ["newtonschool.co"], bundleHints: ["newtonschool"], education: true),
        Rule(name: "Apna College", tint: hex(0x8B5CF6), marks: ["apna college"], domains: ["apnacollege.in"], bundleHints: [], education: true),
        Rule(name: "Elearnmarkets", tint: hex(0x2F6BFF), marks: ["elearnmarkets"], domains: ["elearnmarkets.com"], bundleHints: ["elearnmarkets"], education: true),
        Rule(name: "NPTEL", tint: hex(0x4F7BD9), marks: ["nptel", "swayam"], domains: ["nptel.ac.in", "swayam.gov.in"], bundleHints: [], education: true),
        Rule(name: "Internshala", tint: hex(0x00A5EC), marks: ["internshala trainings"], domains: ["trainings.internshala.com"],
             bundleHints: [], education: true),
        // Course platforms that creators run on their own domains.
        Rule(name: "Online course", tint: hex(0x2BB3A0), marks: [],
             domains: ["teachable.com", "thinkific.com", "kajabi.com", "mykajabi.com", "graphy.com", "classplusapp.com",
                       "learnyst.com", "spayee.com", "podia.com"],
             bundleHints: [], education: true),
    ]

    private static let browserPrefixes = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "company.thebrowser",
                                          "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware", "com.vivaldi",
                                          "com.kagi.kagimacOS", "app.zen-browser"]

    static func isBrowser(_ bundleID: String) -> Bool {
        browserPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The streaming platform behind what's playing, if any.
    @MainActor
    static func detect(bundleID: String, title: String, artist: String, album: String) -> OTTPlatform? {
        guard !bundleID.isEmpty else { return nil }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let platform = platform(forApp: bundleID, appName: app?.localizedName) { return platform }
        // Some pages hand their domain to Now Playing.
        for text in [artist, album, title] {
            if let platform = platform(inText: text) { return platform }
        }
        guard isBrowser(bundleID), let pid = app?.processIdentifier else { return nil }
        // The browser window showing what's playing, if its title says so; else every window.
        let titles = windowTitles(pid: pid)
        let needle = String(title.lowercased().prefix(24))
        let playing = needle.count >= 3 ? titles.filter { $0.lowercased().contains(needle) } : []
        for windowTitle in playing.isEmpty ? titles : playing {
            if let platform = platform(pageTitle: windowTitle) { return platform }
        }
        return nil
    }

    /// Native apps: Prime Video, Apple TV, iPad apps on the Mac, Safari web apps named after a service.
    static func platform(forApp bundleID: String, appName: String?) -> OTTPlatform? {
        let id = bundleID.lowercased()
        if id == "com.apple.tv" { return OTTPlatform(name: "Apple TV", tint: .white) }
        let components = Set(id.split(separator: ".").map(String.init))
        for rule in rules {
            for hint in rule.bundleHints {
                if hint.count >= 5 ? id.contains(hint) : components.contains(hint) { return rule.platform }
            }
        }
        if let name = appName?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty {
            for rule in rules where rule.marks.contains(name) || rule.name.lowercased() == name {
                return rule.platform
            }
        }
        return nil
    }

    /// A domain anywhere in the text ("netflix.com").
    static func platform(inText raw: String) -> OTTPlatform? {
        let text = raw.lowercased()
        guard text.contains(".") else { return nil }
        for rule in rules {
            for domain in rule.domains where containsDomain(text, domain) { return rule.platform }
        }
        return nil
    }

    /// A browser page title such as "Netflix", "Prime Video: The Boys", "Watch … | JioHotstar".
    static func platform(pageTitle raw: String) -> OTTPlatform? {
        let title = raw.lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isYouTube(title) else { return nil }
        if let platform = platform(inText: title) { return platform }
        for rule in rules {
            for mark in rule.marks where matches(title: title, mark: mark) { return rule.platform }
        }
        return nil
    }

    private static let separators = [" | ", " - ", " – ", " — ", " · ", ": ", " : ", " :: "]

    /// Everyday words: only count when the site name ends the title ("… | Max"), never at the start.
    private static let suffixOnlyMarks: Set<String> = ["max", "aha", "treehouse", "scaler", "peacock", "tubi", "starz", "viki", "fubo"]

    private static func matches(title: String, mark: String) -> Bool {
        if title == mark { return true }
        let prefixAllowed = !suffixOnlyMarks.contains(mark)
        for separator in separators {
            if title.hasSuffix(separator + mark) || (prefixAllowed && title.hasPrefix(mark + separator)) { return true }
        }
        return title.hasSuffix(" on " + mark)
    }

    private static func isYouTube(_ title: String) -> Bool {
        if title.hasSuffix("youtube tv") { return false }
        return title == "youtube" || title.hasSuffix(" - youtube") || title.hasSuffix(" – youtube")
            || title.hasSuffix(" — youtube") || title.contains("youtube.com")
    }

    private static func containsDomain(_ text: String, _ domain: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: domain, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            if before == nil || !(before!.isLetter || before!.isNumber || before! == "-") { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Titles of an app's normal windows (including ones on other Spaces).
    private static func windowTitles(pid: pid_t) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let name = window[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    /// "Netflix · 52 min" style line for the player (episode first when the service gives one).
    static func infoLine(platform: OTTPlatform, artist: String, duration: TimeInterval) -> String {
        var parts: [String] = []
        let cleaned = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, OTTDetector.platform(inText: cleaned) == nil, cleaned.lowercased() != platform.name.lowercased() {
            parts.append(cleaned)
        }
        parts.append(platform.name)
        if duration >= 60 {
            let minutes = Int((duration / 60).rounded())
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }
}

/// Artwork-area treatment for streaming services: the artwork (or a platform tile when
/// the page gave none) with a small platform badge, instead of a black mirrored video.
struct OTTArtworkOverlay: View {
    let platform: OTTPlatform
    /// The page gave no artwork (the player fell back to the app icon).
    let showTile: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if showTile {
                ZStack {
                    LinearGradient(colors: [platform.tint.opacity(0.55), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 4) {
                        Image(systemName: platform.isEducation ? "graduationcap.fill" : "play.tv.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(platform.name)
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(platform.tint == .white ? .white : platform.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 6)
                    }
                }
            } else {
                Text(platform.name)
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(platform.tint == .white ? .white : platform.tint)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}
