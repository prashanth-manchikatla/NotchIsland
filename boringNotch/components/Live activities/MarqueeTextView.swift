//
//  MarqueeTextView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 08/08/2024.
//

import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct MeasureSizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: SizePreferenceKey.self, value: geometry.size)
        })
    }
}

struct MarqueeText: View {
    @Binding var text: String
    let font: Font
    let nsFont: NSFont.TextStyle
    let textColor: Color
    let backgroundColor: Color
    let minDuration: Double
    let frameWidth: CGFloat
    
    @State private var animate = false
    @State private var textSize: CGSize = .zero
    @State private var offset: CGFloat = 0
    
    init(_ text: Binding<String>, font: Font = .body, nsFont: NSFont.TextStyle = .body, textColor: Color = .primary, backgroundColor: Color = .clear, minDuration: Double = 3.0, frameWidth: CGFloat = 200) {
        _text = text
        self.font = font
        self.nsFont = nsFont
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.minDuration = minDuration
        self.frameWidth = frameWidth
    }
    
    private var needsScrolling: Bool {
        textSize.width > frameWidth
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HStack(spacing: 20) {
                    Text(text)
                    Text(text)
                        .opacity(needsScrolling ? 1 : 0)
                }
                .id(text)
                .font(font)
                .foregroundColor(textColor)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .background(backgroundColor)
                .modifier(MeasureSizeModifier())
                .onPreferenceChange(SizePreferenceKey.self) { size in
                    let measured = CGSize(width: size.width / 2, height: NSFont.preferredFont(forTextStyle: nsFont).pointSize)
                    if abs(measured.width - textSize.width) > 0.5 || abs(measured.height - textSize.height) > 0.5 {
                        textSize = measured
                    }
                }
            }
            .frame(width: frameWidth, alignment: .leading)
            .clipped()
        }
        .frame(height: textSize.height * 1.3)
        // Hoverbird: scroll once, then rest — same look, without an endless per-frame animation.
        .task(id: "\(text)|\(needsScrolling)|\(Int(textSize.width))") {
            offset = 0
            guard needsScrolling else { return }
            let distance = textSize.width + 20
            let duration = Double(distance / 34)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1.2, minDuration)))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { offset = 0 } // seamless: the copy now sits where the original began
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }
}
