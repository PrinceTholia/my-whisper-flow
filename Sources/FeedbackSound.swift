import AppKit
import Foundation

/// Soft custom start/stop chimes — NOT Wispr Flow’s audio (we don’t copy their assets).
/// Short generated sine “pips” at different pitches; stored once under ~/.whisperapp/.
enum FeedbackSound {
    private static let enabledKey = "feedbackSoundEnabled"
    private static var startURL: URL { URL(fileURLWithPath: KeyStore.dir + "/chime-start.wav") }
    private static var stopURL: URL  { URL(fileURLWithPath: KeyStore.dir + "/chime-stop.wav") }

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func playStart() {
        guard isEnabled else { return }
        ensureChimes()
        NSSound(contentsOf: startURL, byReference: true)?.play()
    }

    static func playStop() {
        guard isEnabled else { return }
        ensureChimes()
        NSSound(contentsOf: stopURL, byReference: true)?.play()
    }

    private static func ensureChimes() {
        try? FileManager.default.createDirectory(atPath: KeyStore.dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: startURL.path) {
            writeSoftPip(to: startURL, frequency: 880, duration: 0.07, volume: 0.28)
        }
        if !FileManager.default.fileExists(atPath: stopURL.path) {
            writeSoftPip(to: stopURL, frequency: 660, duration: 0.06, volume: 0.22)
        }
    }

    /// Tiny mono 16-bit WAV — soft sine with quick fade in/out (no third-party assets).
    private static func writeSoftPip(to url: URL, frequency: Double, duration: Double, volume: Double) {
        let sampleRate = 44100.0
        let n = Int(sampleRate * duration)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env: Double
            let attack = 0.008
            let release = 0.025
            if t < attack {
                env = t / attack
            } else if t > duration - release {
                env = max(0, (duration - t) / release)
            } else {
                env = 1
            }
            let s = sin(2 * Double.pi * frequency * t) * volume * env
            samples[i] = Int16(max(-1, min(1, s)) * Double(Int16.max))
        }

        var data = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        let dataSize = UInt32(n * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)          // PCM chunk size
        appendU16(1)           // PCM
        appendU16(1)           // mono
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2)) // byte rate
        appendU16(2)           // block align
        appendU16(16)          // bits
        data.append(contentsOf: Array("data".utf8))
        appendU32(dataSize)
        for s in samples {
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        try? data.write(to: url, options: .atomic)
    }
}
