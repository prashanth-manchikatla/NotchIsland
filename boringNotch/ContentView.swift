//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject var hub = IslandActivityHub.shared
    @ObservedObject var proximity = ProximityMonitor.shared
    @ObservedObject var interactionLock = IslandInteractionLock.shared
    @Default(.islandMotionStyle) var motionStyle
    @State private var pillWidth: CGFloat = 0
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero
    /// Hoverbird: when the pointer left the open island (for the close safety net).
    @State private var awaySince: Date?
    /// The pointer has been over the open island at least once (shortcut-opened islands wait for that).
    @State private var visitedSinceOpen = false

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private var animationSpring: Animation { motionStyle.interactive }

    /// The island reacts as the pointer approaches (proximity) and when hovered.
    private var proximityScale: CGFloat {
        guard vm.notchState == .closed, !vm.hideOnClosed else { return 1 }
        if isHovering { return 1.07 }
        if let near = proximity.nearScreenUUID, near == vm.screenUUID || (vm.screenUUID == nil && near == NSScreen.main?.displayUUID) {
            return 1.04
        }
        return 1
    }

    /// Opening the island while a live activity runs lands on that activity's tab.
    private func tab(for activity: IslandCompactActivity?) -> NotchViews? {
        switch activity {
        case .recording?, .recordingCountdown?: return .capture
        case .timer?, .timerRinging?, .stopwatch?: return .timers
        case .order?, .iPhoneActivity?, .banner?: return .notifications
        case .calendarSoon?: return .calendar
        case .monitor?: return .monitor
        case .aiAttention?, .aiWorking?, .aiUsage?: return .ai
        case .focus?: return .timers
        case .pill(let pill)?:
            switch pill.kind {
            case .captureSaved: return .capture
            case .copied: return .clipboard
            case .download: return Defaults[.boringShelf] ? .shelf : nil
            default: return nil
            }
        default: return nil
        }
    }

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = vm.closedNotchSize.width + 2 * 78 + 44
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            if vm.notchState == .closed, !vm.hideOnClosed, let secondary = hub.secondary, pillWidth > 0 {
                let d = max(18, vm.effectiveClosedNotchHeight - 6)
                IslandMinimalBubble(activity: secondary, diameter: d)
                    .offset(x: pillWidth / 2 + 7 + d / 2, y: 3)
                    .onTapGesture {
                        if let tab = tab(for: secondary) { coordinator.currentView = tab }
                        doOpen(choosingTab: false)
                    }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .zIndex(3)
            }
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background { IslandBackground(isOpen: vm.notchState == .open) }
                    .clipShape(currentNotchShape)
                    .overlay { IslandRim(shape: currentNotchShape, visible: vm.notchState == .open) }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: IslandPillWidthKey.self, value: geo.size.width)
                    })
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation = motionStyle.open
                        let closeAnimation = motionStyle.close
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose && !IslandInteractionLock.shared.isLocked && !IslandPinState.shared.pinned {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose && !IslandPinState.shared.pinned {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale * proximityScale,
            y: gestureScale * proximityScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .animation(animationSpring, value: proximityScale)
        .animation(animationSpring, value: hub.secondary)
        .onPreferenceChange(IslandPillWidthKey.self) { width in
            if abs(width - pillWidth) > 0.5 { pillWidth = width }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandTopEdgeHit)) { note in
            guard vm.notchState == .closed, !coordinator.firstLaunch,
                  let uuid = note.object as? String,
                  uuid == (vm.screenUUID ?? NSScreen.main?.displayUUID) else { return }
            if Defaults[.enableHaptics] { haptics.toggle() }
            doOpen()
        }
        // Hoverbird: close safety net — runs only while the island is open.
        .task(id: vm.notchState) {
            awaySince = nil
            visitedSinceOpen = false
            guard vm.notchState == .open else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                if Task.isCancelled { return }
                closeIfAbandoned()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandCloseAll)) { _ in
            hoverTask?.cancel()
            isHovering = false
            if vm.notchState == .open { vm.close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandOpenTab)) { note in
            guard let tab = note.object as? NotchViews else { return }
            let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayUUID
            guard !Defaults[.showOnAllDisplays] || vm.screenUUID == mouseScreen else { return }
            coordinator.currentView = tab
            doOpen(choosingTab: false)
        }
        .onChange(of: interactionLock.menuOpen) { _, open in
            // A menu from the island just closed: collapse if the pointer left meanwhile.
            guard !open, vm.notchState == .open, !isHovering else { return }
            if !SharingStateManager.shared.preventNotchClose && !vm.isBatteryPopoverActive && !IslandPinState.shared.pinned { vm.close() }
        }
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose && !IslandPinState.shared.pinned {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        // Hoverbird: iPhone-style "Charging · 82% [battery]" around the camera.
                        IslandChargingActivity()
                            .transition(.blurReplace)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if vm.notchState == .closed, let activity = hub.primary, !vm.hideOnClosed || activity == .recording {
                          IslandCompactActivityView(activity: activity)
                              .id(activityIdentity(activity))
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                HStack(alignment: .top, spacing: 10) {
                    VStack {
                        switch coordinator.currentView {
                        case .home:
                            NotchHomeView(albumArtNamespace: albumArtNamespace)
                        case .shelf:
                            ShelfView()
                        case .clipboard:
                            ClipboardTabView()
                        case .capture:
                            CaptureTabView()
                        case .notifications:
                            NotificationsTabView()
                        case .timers:
                            TimerTabView()
                        case .calendar:
                            IslandCalendarSection()
                        case .shortcuts:
                            ShortcutsTabView()
                        case .monitor:
                            MonitorTabView()
                        case .ai:
                            AITabView()
                        case .notes:
                            NotesTabView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // Hoverbird: the mirror stays visible on every tab (Home shows its own).
                    if vm.isCameraExpanded && coordinator.currentView != .home {
                        CameraPreviewView(webcamManager: webcamManager)
                            .frame(width: 116, height: 116)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.gray)
                        .symbolEffect(.variableColor.iterative, isActive: musicManager.isPlaying)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen(choosingTab: Bool = true) {
        if choosingTab, vm.notchState == .closed, let tab = tab(for: hub.primary) {
            coordinator.currentView = tab
            if case .banner(let banner)? = hub.primary { NotificationMirror.shared.focus(banner.notificationID) }
        }
        withAnimation(motionStyle.open) {
            vm.open()
        }
    }

    private func activityIdentity(_ activity: IslandCompactActivity) -> String {
        switch activity {
        case .pill(let pill): return "pill-\(pill.id)"
        case .banner(let banner): return "banner-\(banner.id)"
        case .order(let id): return "order-\(id)"
        case .iPhoneActivity(let id): return "la-\(id)"
        case .calendarSoon(let id): return "cal-\(id)"
        case .recordingCountdown: return "countdown"
        default: return String(describing: activity)
        }
    }

    // MARK: - Hover Management

    /// The island closes once the pointer has really been away for a moment — even when the
    /// one-off close on leaving was skipped (a popover, a menu or a Notification Center sync was
    /// up at that instant) or a "keep open" flag went stale. Legit reasons to stay open still
    /// count, but only for a while; pinning keeps it open for good.
    private func closeIfAbandoned() {
        guard vm.notchState == .open, !IslandPinState.shared.pinned, !coordinator.firstLaunch else {
            awaySince = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == vm.screenUUID }) ?? NSScreen.main else { return }
        let size = vm.notchSize
        let island = CGRect(x: screen.frame.midX - size.width / 2 - 12, y: screen.frame.maxY - size.height - 24,
                            width: size.width + 24, height: size.height + 24)
        let popovers = NSApp.windows.filter { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
        if island.contains(mouse) || popovers.contains(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(mouse) })
            || NSEvent.pressedMouseButtons != 0 || vm.anyDropZoneTargeting {
            if island.contains(mouse) { visitedSinceOpen = true }
            awaySince = nil
            return
        }
        // Opened from a shortcut or the menu bar and not touched yet: leave it until you do.
        guard visitedSinceOpen else { return }
        // A popover that's already gone can't keep the island open.
        if vm.isBatteryPopoverActive && popovers.isEmpty { vm.isBatteryPopoverActive = false }
        let lock = IslandInteractionLock.shared
        let grace: TimeInterval
        if SharingStateManager.shared.preventNotchClose { grace = 60 }
        else if lock.menuOpen { grace = 30 }
        else if lock.automationActive { grace = 10 }
        else if !popovers.isEmpty { grace = 6 }
        else { grace = 0.8 }
        let now = Date()
        guard let since = awaySince else {
            awaySince = now
            return
        }
        guard now.timeIntervalSince(since) >= grace else { return }
        awaySince = nil
        hoverTask?.cancel()
        isHovering = false
        vm.isBatteryPopoverActive = false
        vm.close()
    }

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose && !IslandInteractionLock.shared.isLocked && !IslandPinState.shared.pinned {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                IslandPinState.shared.pinned = false
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}



/// Width of the compact island, used to place the detached "minimal" bubble.
struct IslandPillWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
