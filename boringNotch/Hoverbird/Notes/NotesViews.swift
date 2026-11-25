//
//  NotesViews.swift
//  Hoverbird · Notes
//
//  • Notes tab in the island: tick to-dos off, glance at your note. ＋ / ✎ open the panel.
//  • Notes panel: a small glass panel under the notch for typing (the island itself never
//    takes the keyboard, so it can't steal focus from your app). Esc or clicking away closes it.
//

import AppKit
import SwiftUI

// MARK: - Island tab

struct NotesTabView: View {
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LiveCard(width: nil, tint: .yellow) {
                VStack(alignment: .leading, spacing: 5) {
                    header(symbol: "checklist", title: store.openCount > 0 ? "To-do · \(store.openCount) left" : "To-do",
                           button: "plus", help: "Add a to-do") { NotesPanelController.shared.show(focus: .todo) }
                    if store.todos.isEmpty {
                        Text("Nothing to do. Add one with ＋.").font(.system(size: 10.5)).foregroundStyle(.gray)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(store.todos) { item in TodoRow(item: item) }
                            }
                        }
                    }
                }
            }
            LiveCard(width: nil, tint: .yellow) {
                VStack(alignment: .leading, spacing: 5) {
                    header(symbol: "note.text", title: "Note", button: "pencil", help: "Edit the note") {
                        NotesPanelController.shared.show(focus: .note)
                    }
                    Text(store.note.isEmpty ? "Jot something down…" : store.note)
                        .font(.system(size: 11)).foregroundStyle(store.note.isEmpty ? .gray : .white.opacity(0.9))
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { NotesPanelController.shared.show(focus: .note) }
                }
            }
        }
        .frame(height: 128)
        .padding(.top, 2)
    }

    private func header(symbol: String, title: String, button: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.yellow)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: action) {
                Image(systemName: button).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

struct TodoRow: View {
    let item: TodoItem
    var large = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button { NotesStore.shared.toggle(item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: large ? 15 : 12, weight: .medium))
                    .foregroundStyle(item.done ? .green : .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            Text(item.text)
                .font(.system(size: large ? 13 : 11))
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .gray : .white)
                .lineLimit(large ? 2 : 1)
            Spacer(minLength: 0)
            if hovering {
                Button { NotesStore.shared.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Panel (typing)

final class NotesPanelController: NSObject, NSWindowDelegate {
    static let shared = NotesPanelController()
    enum Focus { case todo, note }
    private var panel: NotesPanel?
    private let model = NotesPanelModel()
    static let size = NSSize(width: 440, height: 420)

    @MainActor
    func show(focus: Focus) {
        if panel == nil {
            let p = NotesPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.title = "Hoverbird Notes"
            let host = NSHostingView(rootView: NotesPanelView(model: model)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: Self.size)
            p.contentView = host
            p.delegate = self
            panel = p
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2, y: screen.visibleFrame.maxY - Self.size.height - 10,
                              width: Self.size.width, height: Self.size.height), display: false)
        NotificationCenter.default.post(name: .islandCloseAll, object: nil)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        model.focus = focus
        model.focusToken += 1
        // A click in any other app closes it, like Spotlight (clicks inside the panel are local events).
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                MainActor.assumeIsolated { NotesPanelController.shared.close() }
            }
        }
    }

    private var clickMonitor: Any?

    @MainActor
    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
    }
}

/// Borderless panels don't take the keyboard by default; this one must (it's where you type).
final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { NotesPanelController.shared.close() } }
}

final class NotesPanelModel: ObservableObject {
    @Published var focus: NotesPanelController.Focus = .todo
    @Published var focusToken = 0
}

private struct NotesPanelView: View {
    @ObservedObject var model: NotesPanelModel
    @ObservedObject private var store = NotesStore.shared
    @State private var draft = ""
    @FocusState private var focused: Field?
    private enum Field { case todo, note }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Notes", systemImage: "checklist").font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.todos.contains(where: \.done) {
                    Button("Clear done") { store.clearDone() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                Button { NotesPanelController.shared.close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)")
            }
            TextField("Add a to-do, press Return", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .todo)
                .onSubmit { store.add(draft); draft = "" }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.todos) { item in TodoRow(item: item, large: true) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            Divider()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.note)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused, equals: .note)
                if store.note.isEmpty {
                    Text("Quick note…").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 130)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.6))
        .padding(6)
        .preferredColorScheme(.dark)
        .onChange(of: model.focusToken) {
            focused = model.focus == .todo ? .todo : .note
        }
        .onAppear {
            // First open: the panel has to become key before a field can take focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = model.focus == .todo ? .todo : .note }
        }
    }
}
