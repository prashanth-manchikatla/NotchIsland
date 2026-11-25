//
//  NotesStore.swift
//  Hoverbird · Notes
//
//  A to-do list and one quick note, always a hover away. Saved on this Mac only
//  (Application Support/Hoverbird/notes.json). Ticked-off to-dos clear themselves
//  after a day, so the list stays short.
//

import Foundation
import SwiftUI

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var doneAt: Date?
    var created = Date()
}

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var todos: [TodoItem] = [] { didSet { scheduleSave() } }
    @Published var note: String = "" { didSet { scheduleSave() } }

    private struct Saved: Codable { var todos: [TodoItem]; var note: String }
    private let url = IslandPaths.appSupport.appendingPathComponent("notes.json")
    private var saveTask: Task<Void, Never>?
    private var loading = false

    private init() {
        load()
        clearOldDone()
    }

    var openCount: Int { todos.filter { !$0.done }.count }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.smooth(duration: 0.25)) { todos.insert(TodoItem(text: trimmed), at: 0) }
    }

    func toggle(_ id: UUID) {
        guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth(duration: 0.25)) {
            todos[i].done.toggle()
            todos[i].doneAt = todos[i].done ? Date() : nil
            // Done ones sink below the open ones.
            todos.sort { !$0.done && $1.done }
        }
    }

    func remove(_ id: UUID) {
        withAnimation(.smooth(duration: 0.25)) { todos.removeAll { $0.id == id } }
    }

    func clearDone() {
        withAnimation(.smooth(duration: 0.25)) { todos.removeAll(where: \.done) }
    }

    private func clearOldDone() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let kept = todos.filter { !($0.done && ($0.doneAt ?? .distantPast) < cutoff) }
        if kept.count != todos.count { todos = kept }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        loading = true
        todos = saved.todos
        note = saved.note
        loading = false
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveTask?.cancel()
        let snapshot = Saved(todos: todos, note: note)
        let url = self.url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
