//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    // NotchIsland
    static let openClipboard = Self("openClipboard", default: .init(.c, modifiers: [.control, .option]))
    static let toggleAwake = Self("toggleAwake", default: .init(.a, modifiers: [.control, .option]))
    static let openLiveTab = Self("openLiveTab", default: .init(.l, modifiers: [.control, .option]))
    static let screenshotSelection = Self("screenshotSelection")
    static let screenshotFullScreen = Self("screenshotFullScreen")
    static let toggleScreenRecording = Self("toggleScreenRecording")
    static let recordSelection = Self("recordSelection")
    static let copyTextFromScreen = Self("copyTextFromScreen", default: .init(.two, modifiers: [.shift, .command]))
    static let pickColorFromScreen = Self("pickColorFromScreen")
    static let toggleMicMute = Self("toggleMicMute", default: .init(.m, modifiers: [.control, .option]))
    static let pastePlainText = Self("pastePlainText", default: .init(.v, modifiers: [.control, .option]))
    // Window snapping (front window)
    static let snapLeft = Self("snapLeft", default: .init(.leftArrow, modifiers: [.control, .option]))
    static let snapRight = Self("snapRight", default: .init(.rightArrow, modifiers: [.control, .option]))
    static let snapTop = Self("snapTop", default: .init(.upArrow, modifiers: [.control, .option]))
    static let snapBottom = Self("snapBottom", default: .init(.downArrow, modifiers: [.control, .option]))
    static let snapFill = Self("snapFill", default: .init(.return, modifiers: [.control, .option]))
    static let snapRestore = Self("snapRestore", default: .init(.delete, modifiers: [.control, .option]))
    static let snapLeftThird = Self("snapLeftThird", default: .init(.d, modifiers: [.control, .option]))
    static let snapCenterThird = Self("snapCenterThird", default: .init(.f, modifiers: [.control, .option]))
    static let snapRightThird = Self("snapRightThird", default: .init(.g, modifiers: [.control, .option]))
}
