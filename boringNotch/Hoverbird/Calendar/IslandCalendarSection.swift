//
//  IslandCalendarSection.swift
//  Hoverbird
//
//  📅 Calendar section (opened from the header): your events with the date
//  wheel, the time, and local weather with a short forecast.
//

import SwiftUI

struct IslandCalendarSection: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CalendarView()
                .frame(width: 280)
                .onHover { vm.isHoveringCalendar = $0 }
                .environmentObject(vm)
            VStack(spacing: 8) {
                TodayInfoCard()
                WeatherCard()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 134)
        .padding(.top, 2)
    }
}

/// The time, above the weather (the calendar beside it already shows the date).
private struct TodayInfoCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(context.date.formatted(.dateTime.second(.twoDigits)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
                Text(Self.amPM(context.date))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                    .padding(.leading, 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        }
        .frame(height: 56)
    }

    private static let symbols: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter
    }()

    /// 24-hour locales have no AM/PM part.
    private static let uses12Hour = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")

    private static func amPM(_ date: Date) -> String {
        guard uses12Hour else { return "" }
        return Calendar.current.component(.hour, from: date) < 12 ? symbols.amSymbol : symbols.pmSymbol
    }
}

private struct WeatherCard: View {
    @ObservedObject private var weather = WeatherManager.shared

    var body: some View {
        Group {
            if let w = weather.snapshot {
                HStack(spacing: 10) {
                    Image(systemName: WeatherManager.symbol(w.code, isDay: w.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 24))
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(w.temperature.rounded()))° \(WeatherManager.describe(w.code))")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text("\(w.city ?? "Here") · H \(Int(w.high.rounded()))° L \(Int(w.low.rounded()))°")
                            .font(.system(size: 10.5)).foregroundStyle(.gray).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(w.days.dropFirst().prefix(3)) { day in
                            VStack(spacing: 1) {
                                Text(day.day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
                                Image(systemName: WeatherManager.symbol(day.code))
                                    .symbolRenderingMode(.multicolor).font(.system(size: 11))
                                Text("\(Int(day.high.rounded()))°").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white)
                            }
                        }
                    }
                    Color.clear.frame(width: 0)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "location.circle").font(.system(size: 20)).foregroundStyle(.gray)
                    switch weather.status {
                    case .needsPermission:
                        Text("Allow Location to see your weather").font(.system(size: 11)).foregroundStyle(.gray)
                    case .denied:
                        Button("Turn on Location for Hoverbird…") { weather.openLocationSettings() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                    case .failed:
                        Button("Weather unavailable — retry") { weather.refresh() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                    default:
                        Text("Loading weather…").font(.system(size: 11)).foregroundStyle(.gray)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .onAppear { weather.refreshIfNeeded() }
    }
}

struct CalendarHeaderButton: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    var body: some View {
        let active = coordinator.currentView == .calendar
        HeaderCircleButton(title: "Calendar", help: "Calendar, events and weather",
                           tap: { withAnimation(.smooth) { coordinator.currentView = active ? .home : .calendar } }) {
            Image(systemName: active ? "calendar.circle.fill" : "calendar")
                .foregroundStyle(active ? Color.red : Color.white)
                .imageScale(.medium)
        }
    }
}
