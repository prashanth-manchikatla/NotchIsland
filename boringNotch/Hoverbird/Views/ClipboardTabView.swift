//
//  ClipboardTabView.swift
//  Hoverbird
//

import Defaults
import SwiftUI

struct ClipboardTabView: View {
    @ObservedObject private var clipboard = ClipboardManager.shared
    @Default(.clipboardEnabled) private var enabled
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "All", text = "Text", links = "Links", images = "Images", files = "Files", pinned = "Pinned"
        var symbol: String {
            switch self {
            case .all: return "square.stack.fill"
            case .text: return "text.alignleft"
            case .links: return "link"
            case .images: return "photo"
            case .files: return "doc"
            case .pinned: return "pin.fill"
            }
        }
    }

    private var filtered: [ClipItem] {
        let items = clipboard.items
        switch filter {
        case .all: return items.sorted { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
        case .text: return items.filter { $0.kind == .text || $0.kind == .color }
        case .links: return items.filter { $0.kind == .link }
        case .images: return items.filter { $0.kind == .image }
        case .files: return items.filter { $0.kind == .file }
        case .pinned: return items.filter(\.pinned)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Filter.allCases, id: \.self) { option in
                    Button {
                        withAnimation(.snappy) { filter = option }
                    } label: {
                        Label(option.rawValue, systemImage: option.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(filter == option ? Color.white.opacity(0.18) : Color.white.opacity(0.06)))
                            .foregroundStyle(filter == option ? .white : .gray)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !clipboard.items.isEmpty {
                    Text("\(clipboard.items.count)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.gray)
                    Button {
                        clipboard.clear(keepPinned: true)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Clear history (keeps pinned)")
                }
            }

            if !enabled {
                EmptyStateLine(symbol: "doc.on.clipboard", text: "Clipboard history is off — turn it on in Settings › Clipboard")
            } else if filtered.isEmpty {
                BirdEmptyState(title: filter == .all ? "Nothing copied yet" : "Nothing here yet",
                               detail: filter == .all ? "Copy anything — it stacks up here. Press ⌘C twice to open." : nil)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(filtered) { item in
                            ClipCard(item: item, isLatest: item.id == clipboard.items.first?.id)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: 112)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

private struct ClipCard: View {
    let item: ClipItem
    let isLatest: Bool
    @ObservedObject private var clipboard = ClipboardManager.shared
    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if let bundle = item.sourceBundleID, let icon = AppIconAsNSImage(for: bundle) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                }
                Image(systemName: kindSymbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.gray)
                Spacer(minLength: 0)
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Text(item.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: 136, height: 108)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.13 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isLatest ? Color.white.opacity(0.22) : Color.white.opacity(0.05), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                HStack(spacing: 6) {
                    iconButton(item.pinned ? "pin.slash.fill" : "pin.fill", help: item.pinned ? "Unpin" : "Pin") {
                        clipboard.togglePin(item)
                    }
                    iconButton("trash.fill", help: "Delete") { clipboard.delete(item) }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .overlay {
            if justCopied {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.55))
                    .overlay(Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green))
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture {
            clipboard.select(item)
            withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeIn(duration: 0.2)) { justCopied = false }
            }
        }
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Button("Paste into front app") { clipboard.paste(item) }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            if item.kind == .link, let url = URL(string: item.text ?? "") {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            if item.kind == .file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
            }
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
        .help("Click to \(Defaults[.clipboardPasteOnSelect] ? "paste" : "copy")")
    }

    private var kindSymbol: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(clipboard.preview(for: item))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(5)
        case .link:
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(string: item.text ?? "")?.host() ?? "Link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.text ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.cyan.opacity(0.9))
                    .lineLimit(3)
            }
        case .color:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ClipboardManager.color(from: item.text) ?? .gray)
                    .frame(width: 34, height: 34)
                Text(item.text ?? "")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        case .image:
            if let thumb = clipboard.thumbnail(for: item) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.gray)
            }
        case .file:
            let urls = item.fileURLs
            VStack(alignment: .leading, spacing: 4) {
                if let first = urls.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                        .resizable()
                        .frame(width: 30, height: 30)
                }
                Text(clipboard.preview(for: item))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.black.opacity(0.65)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct EmptyStateLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.gray)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}
