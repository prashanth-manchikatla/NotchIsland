//
//  OrderTracker.swift
//  NotchIsland
//
//  Turns order / delivery / ride notifications (mirrored from your iPhone)
//  into a persistent Live Activity in the island: who, what stage, and a
//  live ETA countdown — like the iPhone's Dynamic Island.
//

import AppKit
import Combine
import Defaults
import SwiftUI

struct OrderActivity: Identifiable, Equatable {
    enum Category: String { case food, grocery, ride, package, generic }

    enum Stage: Int, Comparable, CaseIterable {
        case placed = 0, preparing, onTheWay, arriving, delivered
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .placed: return "Placed"
            case .preparing: return "Preparing"
            case .onTheWay: return "On the way"
            case .arriving: return "Arriving"
            case .delivered: return "Delivered"
            }
        }
    }

    let id: UUID
    var appName: String
    var bundleID: String?
    var category: Category
    var stage: Stage
    var headline: String
    var detail: String
    var eta: Date?
    var updated: Date
    var isFromIPhone: Bool

    var tint: Color {
        switch stage {
        case .placed, .preparing: return .orange
        case .onTheWay: return .cyan
        case .arriving: return .green
        case .delivered: return .green
        }
    }
}

@MainActor
final class OrderTracker: ObservableObject {
    static let shared = OrderTracker()

    @Published private(set) var orders: [OrderActivity] = []
    private var cleanupTimer: Timer?

    /// The order shown in the compact island.
    var primaryOrder: OrderActivity? {
        orders.first { $0.stage != .delivered || Date().timeIntervalSince($0.updated) < 300 }
    }

    // App name fragments (lowercased) → category.
    private static let knownApps: [(String, OrderActivity.Category)] = [
        ("swiggy", .food), ("zomato", .food), ("uber eats", .food), ("doordash", .food), ("grubhub", .food),
        ("deliveroo", .food), ("just eat", .food), ("postmates", .food), ("eatsure", .food), ("domino", .food),
        ("mcdonald", .food), ("kfc", .food), ("pizza hut", .food), ("starbucks", .food), ("magicpin", .food),
        ("talabat", .food), ("foodpanda", .food), ("grabfood", .food), ("wolt", .food), ("box8", .food),
        ("blinkit", .grocery), ("zepto", .grocery), ("instamart", .grocery), ("bigbasket", .grocery),
        ("bb now", .grocery), ("dunzo", .grocery), ("jiomart", .grocery), ("instacart", .grocery),
        ("gopuff", .grocery), ("flipkart minutes", .grocery), ("swiggy instamart", .grocery), ("getir", .grocery),
        ("uber", .ride), ("ola", .ride), ("rapido", .ride), ("lyft", .ride), ("bolt", .ride),
        ("namma yatri", .ride), ("blusmart", .ride), ("indrive", .ride), ("careem", .ride), ("grab", .ride),
        ("amazon", .package), ("flipkart", .package), ("myntra", .package), ("meesho", .package),
        ("ajio", .package), ("nykaa", .package), ("fedex", .package), ("ups", .package), ("usps", .package),
        ("dhl", .package), ("blue dart", .package), ("bluedart", .package), ("delhivery", .package),
        ("ekart", .package), ("shiprocket", .package), ("aliexpress", .package), ("temu", .package),
        ("shein", .package), ("ebay", .package), ("etsy", .package), ("apple store", .package),
        ("tata cliq", .package), ("croma", .package), ("reliance digital", .package),
    ]

    private static let strongPhrases = [
        "out for delivery", "on the way", "on its way", "arriving in", "arriving at", "will arrive",
        "is arriving", "picked up your", "order has been", "your order", "delivery partner", "has been delivered",
        "was delivered", "driver is", "your driver", "your ride", "captain is", "valet", "mins away", "min away",
        "minutes away", "is nearby", "reached your", "order is ready", "order placed", "order confirmed",
        "shipped", "dispatched", "out-for-delivery", "track your order", "eta",
    ]

    private static let weakWords = [
        "order", "delivery", "delivered", "rider", "driver", "pickup", "picked", "arriving", "arrived",
        "preparing", "packed", "otp", "trip", "parcel", "package", "shipment", "courier",
    ]

    private init() {
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { OrderTracker.shared.cleanup() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    // MARK: - Ingest

    /// Returns true if the notification looked like an order / ride update.
    @discardableResult
    func ingest(_ note: MirroredNotification) -> Bool {
        let app = note.appName.lowercased()
        let text = (note.title + " " + note.body).lowercased()
        let extra = Defaults[.orderTrackingExtraKeywords].map { $0.lowercased() }.filter { !$0.isEmpty }

        let known = Self.knownApps.first { Self.matches(app, $0.0) }
        let strong = Self.strongPhrases.contains { Self.matches(text, $0) } || extra.contains { text.contains($0) || app.contains($0) }
        let weakHits = Self.weakWords.filter { Self.matches(text, $0) }.count
        guard known != nil || strong || weakHits >= 2 else { return false }
        // A known app that isn't talking about an order (e.g. a promo) shouldn't create one.
        if known != nil && !strong && weakHits == 0 && orders.first(where: { $0.appName == note.appName }) == nil {
            return false
        }

        let category = known?.1 ?? Self.guessCategory(text)
        let stage = Self.stage(from: text)
        let eta = Self.eta(from: text)

        if let index = orders.firstIndex(where: { $0.appName.caseInsensitiveCompare(note.appName) == .orderedSame }) {
            var order = orders[index]
            // Don't let a stray "order placed" reminder move a delivery backwards.
            if let stage, stage >= order.stage || stage == .delivered { order.stage = stage }
            order.headline = note.title
            order.detail = note.body
            if let eta { order.eta = eta } else if order.stage == .delivered { order.eta = nil }
            order.updated = Date()
            order.isFromIPhone = order.isFromIPhone || note.isFromIPhone
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                orders.remove(at: index)
                orders.insert(order, at: 0)
            }
        } else {
            let order = OrderActivity(
                id: UUID(), appName: note.appName, bundleID: note.bundleID, category: category,
                stage: stage ?? .placed, headline: note.title, detail: note.body, eta: eta,
                updated: Date(), isFromIPhone: note.isFromIPhone)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                orders.insert(order, at: 0)
            }
        }
        return true
    }

    func dismiss(_ order: OrderActivity) {
        withAnimation { orders.removeAll { $0.id == order.id } }
    }

    func dismissAll() {
        withAnimation { orders.removeAll() }
    }

    func symbol(forAppNamed name: String) -> String {
        let app = name.lowercased()
        let category = Self.knownApps.first { Self.matches(app, $0.0) }?.1 ?? .generic
        return Self.symbol(for: category)
    }

    static func symbol(for category: OrderActivity.Category) -> String {
        switch category {
        case .food: return "takeoutbag.and.cup.and.straw.fill"
        case .grocery: return "cart.fill"
        case .ride: return "car.fill"
        case .package: return "shippingbox.fill"
        case .generic: return "bag.fill"
        }
    }

    /// Short trailing text for the compact island.
    static func compactText(for order: OrderActivity, now: Date = Date()) -> String {
        if order.stage == .delivered { return order.category == .ride ? "Done" : "Delivered" }
        if let eta = order.eta {
            let minutes = Int((eta.timeIntervalSince(now) / 60).rounded(.up))
            if minutes <= 0 { return "Now" }
            if minutes < 60 { return "\(minutes) min" }
            return Self.timeFormatter.string(from: eta)
        }
        switch order.stage {
        case .placed: return "Placed"
        case .preparing: return order.category == .ride ? "Assigned" : "Preparing"
        case .onTheWay: return "On way"
        case .arriving: return "Arriving"
        case .delivered: return "Done"
        }
    }

    // MARK: - Parsing

    /// Substring match for longer phrases; whole-word match for short tokens
    /// ("ups", "ola", "eta") so they don't fire inside other words.
    static func matches(_ haystack: String, _ needle: String) -> Bool {
        if needle.count > 4 { return haystack.contains(needle) }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    private func cleanup() {
        let now = Date()
        let kept = orders.filter { order in
            if order.stage == .delivered { return now.timeIntervalSince(order.updated) < 15 * 60 }
            return now.timeIntervalSince(order.updated) < 3 * 3600
        }
        if kept.count != orders.count { withAnimation { orders = kept } }
    }

    private static func guessCategory(_ text: String) -> OrderActivity.Category {
        if text.contains("ride") || text.contains("driver") || text.contains("trip") || text.contains("captain") { return .ride }
        if text.contains("shipped") || text.contains("package") || text.contains("parcel") || text.contains("courier") { return .package }
        if text.contains("food") || text.contains("restaurant") || text.contains("meal") { return .food }
        return .generic
    }

    private static func stage(from text: String) -> OrderActivity.Stage? {
        let rules: [(OrderActivity.Stage, [String])] = [
            (.delivered, ["has been delivered", "was delivered", "delivered", "enjoy your", "order complete",
                          "completed", "trip ended", "you have arrived", "thanks for riding", "rate your"]),
            (.arriving, ["arriving", "nearby", "almost there", "reached", "at your door", "has arrived", "is here",
                         "arrived", "outside", "at your location", "few minutes away", "1 min away", "2 mins away"]),
            (.onTheWay, ["on the way", "on its way", "out for delivery", "out-for-delivery", "picked up", "en route",
                         "heading to", "is coming", "started", "dispatched from", "in transit"]),
            (.preparing, ["preparing", "being prepared", "packed", "packing", "accepted", "confirmed", "assigned",
                          "shipped", "dispatched", "ready", "cooking", "getting your order"]),
            (.placed, ["placed", "received your order", "booked", "order received"]),
        ]
        for (stage, words) in rules where words.contains(where: { text.contains($0) }) {
            return stage
        }
        return nil
    }

    private static func eta(from text: String, now: Date = Date()) -> Date? {
        // "in 10-12 mins", "12 min away", "arriving in 5 minutes"
        if let match = text.range(of: #"(\d{1,3})\s*(?:-|–|to)?\s*(\d{1,3})?\s*(?:mins?|minutes?)\b"#, options: .regularExpression) {
            let numbers = text[match].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if let minutes = numbers.max(), minutes > 0, minutes < 600 {
                return now.addingTimeInterval(TimeInterval(minutes * 60))
            }
        }
        // "in 1 hr", "2 hours"
        if let match = text.range(of: #"(\d{1,2})\s*(?:hrs?|hours?)\b"#, options: .regularExpression) {
            let numbers = text[match].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if let hours = numbers.first, hours > 0, hours < 24 { return now.addingTimeInterval(TimeInterval(hours * 3600)) }
        }
        // "by 7:45 pm"
        if let match = text.range(of: #"(\d{1,2}):(\d{2})\s*(am|pm)?"#, options: .regularExpression) {
            let token = String(text[match])
            let digits = token.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            guard digits.count >= 2 else { return nil }
            var hour = digits[0]
            let minute = digits[1]
            if token.contains("pm"), hour < 12 { hour += 12 }
            if token.contains("am"), hour == 12 { hour = 0 }
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour
            comps.minute = minute
            if var date = Calendar.current.date(from: comps) {
                if date < now.addingTimeInterval(-600) { date = date.addingTimeInterval(86400) }
                if date.timeIntervalSince(now) < 12 * 3600 { return date }
            }
        }
        return nil
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
