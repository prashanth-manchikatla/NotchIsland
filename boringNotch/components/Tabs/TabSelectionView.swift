//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    /// Stable id (also what Settings › Island › Tabs stores to hide a tab).
    let id: String
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(id: "home", label: "Home", icon: "house.fill", view: .home),
    TabModel(id: "shelf", label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(id: "clipboard", label: "Clipboard", icon: "doc.on.clipboard.fill", view: .clipboard),
    TabModel(id: "capture", label: "Capture", icon: "camera.viewfinder", view: .capture),
    TabModel(id: "notifications", label: "Notifications", icon: "bell.fill", view: .notifications),
    TabModel(id: "timers", label: "Timer", icon: "timer", view: .timers),
    TabModel(id: "notes", label: "Notes", icon: "checklist", view: .notes),
    TabModel(id: "ai", label: "AI Usage", icon: "sparkle", view: .ai),
    TabModel(id: "shortcuts", label: "Shortcuts", icon: "square.stack.3d.up.fill", view: .shortcuts),
    TabModel(id: "monitor", label: "Monitor", icon: "gauge.with.dots.needle.67percent", view: .monitor),
]

/// Hoverbird: the tabs shown (Shelf needs the shelf on; any tab but Home can be hidden in Settings › Island).
@MainActor func visibleTabs() -> [TabModel] {
    let hidden = Set(Defaults[.islandHiddenTabs])
    return tabs.filter { tab in
        if tab.view == .shelf && !Defaults[.boringShelf] { return false }
        if tab.view == .ai && !Defaults[.aiUsageEnabled] { return false }
        return tab.view == .home || !hidden.contains(tab.id)
    }
}

struct TabSelectionView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var notifications = NotificationMirror.shared
    @Default(.islandHiddenTabs) private var hiddenTabs
    @Namespace var animation

    /// Tabs share the space left of the notch (~200 pt); with more tabs each button gets narrower.
    private func buttonWidth(count: Int) -> CGFloat {
        let side = (openNotchSize.width - 2 * (cornerRadiusInsets.opened.bottom + 12) - vm.closedNotchSize.width) / 2 - 4
        return max(20, min(26, side / CGFloat(max(1, count))))
    }

    var body: some View {
        let shown = visibleTabs()
        let width = buttonWidth(count: shown.count)
        HStack(spacing: 0) {
            ForEach(shown) { tab in
                let selected = coordinator.currentView == tab.view
                TabButton(label: tab.label, icon: tab.icon, selected: selected, width: width) {
                    withAnimation(.smooth) {
                        coordinator.currentView = tab.view
                    }
                }
                .frame(height: 28)
                .foregroundStyle(selected ? .white : .gray)
                .background {
                    // Selected tab: a sliding capsule. (No clipping here, so hover tags can show.)
                    if selected {
                        Capsule()
                            .fill(Color(nsColor: .secondarySystemFill))
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Hoverbird: unread notifications.
                    if tab.view == .notifications && notifications.unreadCount > 0 {
                        Circle().fill(Color.blue).frame(width: 6, height: 6).offset(x: -4, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .zIndex(selected ? 1 : 0)
            }
        }
    }
}
