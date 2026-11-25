//
//  UpcomingEventMonitor.swift
//  Hoverbird
//
//  "Standup in 5 min" — shows your next meeting as a Live Activity shortly
//  before it starts, with a one-click Join button for Zoom / Meet / Teams /
//  Webex / FaceTime links. Re-evaluates only at exact time boundaries and on
//  calendar changes (no polling).
//

import AppKit
import Combine
import Defaults
import EventKit
import SwiftUI

struct UpcomingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?
    let color: Color
}

@MainActor
final class UpcomingEventMonitor: ObservableObject {
    static let shared = UpcomingEventMonitor()

    @Published private(set) var upcoming: UpcomingEvent?

    private let store = EKEventStore()
    private var boundaryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var storeObserver: Any?

    private init() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in MainActor.assumeIsolated { UpcomingEventMonitor.shared.evaluate() } }

        Defaults.publisher(.calendarUpcomingActivity)
            .combineLatest(Defaults.publisher(.calendarUpcomingLeadMinutes))
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.evaluate() }
            .store(in: &cancellables)

        // Calendar permission may be granted later from the Calendar tab.
        CalendarManager.shared.$calendarAuthorizationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { UpcomingEventMonitor.shared.evaluate() } }
    }

    private var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func evaluate() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard Defaults[.calendarUpcomingActivity], hasAccess else {
            if upcoming != nil { upcoming = nil }
            return
        }
        let now = Date()
        let lead = TimeInterval(max(1, Defaults[.calendarUpcomingLeadMinutes]) * 60)
        let grace: TimeInterval = 5 * 60
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-grace),
                                                 end: now.addingTimeInterval(12 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }

        // Show from `lead` before the start until 5 minutes after it.
        let current = events.first { $0.startDate.addingTimeInterval(-lead) <= now && now < $0.startDate.addingTimeInterval(grace) }
        let newValue = current.map { event in
            UpcomingEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Event",
                          start: event.startDate, end: event.endDate, joinURL: Self.meetingURL(for: event),
                          color: Color(nsColor: event.calendar?.color ?? .systemBlue))
        }
        if newValue != upcoming {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { upcoming = newValue }
        }

        // Next moment anything can change.
        var boundaries: [Date] = []
        if let current { boundaries.append(current.startDate.addingTimeInterval(grace)) }
        if let next = events.first(where: { $0.startDate.addingTimeInterval(-lead) > now }) {
            boundaries.append(next.startDate.addingTimeInterval(-lead))
        }
        if let fire = boundaries.min() {
            let timer = Timer(fire: fire.addingTimeInterval(0.5), interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { UpcomingEventMonitor.shared.evaluate() }
            }
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            boundaryTimer = timer
        }
    }

    func join(_ event: UpcomingEvent) {
        if let url = event.joinURL { NSWorkspace.shared.open(url) }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    static func meetingURL(for event: EKEvent) -> URL? {
        let haystack = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com|whereby\.com|gotomeet|chime\.aws)[^\s<>"]*"#
        if let range = haystack.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return URL(string: String(haystack[range]))
        }
        return nil
    }
}
