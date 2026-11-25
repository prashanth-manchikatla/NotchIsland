//
//  FocusSounds.swift
//  Hoverbird · Focus
//
//  Background noise for focusing, synthesised on the fly (no audio files): white, pink,
//  brown (deep, the popular "focus" one) and ocean (brown noise with slow swells).
//  Runs only while a focus session plays it; fades in and out.
//

import AVFoundation
import Defaults

enum FocusSound: String, CaseIterable, Identifiable, Defaults.Serializable {
    case off = "Off"
    case brown = "Brown noise"
    case pink = "Pink noise"
    case white = "White noise"
    case ocean = "Ocean"
    var id: String { rawValue }
}

final class FocusSounds {
    static let shared = FocusSounds()

    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private let state = NoiseState()
    private var current: FocusSound = .off

    /// Generator state, touched only by the audio render thread (plus `kind` / `gain` set once per change).
    private final class NoiseState {
        var kind: FocusSound = .brown
        var gain: Float = 0          // smoothed towards target
        var target: Float = 0.3
        var seed: UInt32 = 22_222
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
        var brown: Float = 0
        var phase: Float = 0
        var sampleRate: Float = 48_000

        @inline(__always) func white() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }

        @inline(__always) func next() -> Float {
            let w = white()
            switch kind {
            case .white, .off:
                return w * 0.35
            case .pink: // Paul Kellet's refined pink filter
                b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759
                b2 = 0.96900 * b2 + w * 0.1538520; b3 = 0.86650 * b3 + w * 0.3104856
                b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
                let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
                b6 = w * 0.115926
                return pink * 0.11
            case .brown, .ocean:
                brown = (brown + 0.02 * w) / 1.02
                var v = brown * 3.5
                if kind == .ocean {
                    phase += 1 / (sampleRate * 9) // one swell every ~9 s
                    if phase > 1 { phase -= 1 }
                    let swell = 0.55 + 0.45 * sinf(phase * 2 * .pi)
                    v *= swell * swell
                }
                return v
            }
        }
    }

    func play(_ sound: FocusSound, volume: Float) {
        guard sound != .off else { stop(); return }
        state.target = max(0, min(1, volume))
        if engine != nil, current == sound { return }
        stopNow()
        current = sound
        state.kind = sound
        state.gain = 0

        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        state.sampleRate = Float(format.sampleRate)
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        let s = state
        let node = AVAudioSourceNode(format: mono) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<Int(frameCount) {
                s.gain += (s.target - s.gain) * 0.0002 // ~0.1 s fades
                out[i] = s.next() * s.gain
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        do {
            try engine.start()
            self.engine = engine
            source = node
        } catch {
            current = .off
        }
    }

    /// Fades out, then stops the engine.
    func stop() {
        guard engine != nil else { return }
        state.target = 0
        let stopping = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.engine === stopping, self.state.target == 0 else { return }
            self.stopNow()
        }
    }

    private func stopNow() {
        engine?.stop()
        if let source { engine?.detach(source) }
        engine = nil
        source = nil
        current = .off
    }
}
