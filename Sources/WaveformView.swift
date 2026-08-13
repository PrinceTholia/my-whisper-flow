import SwiftUI

/// Legacy full-width waveform — kept for compatibility; recording UI now uses `RecordingPill`.
struct WaveformView: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var bars: [CGFloat] = Array(repeating: 0.08, count: 24)
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.5 + Double(bars[i]) * 0.4))
                    .frame(width: 3, height: max(4, bars[i] * 36))
            }
        }
        .frame(width: 180, height: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .onReceive(timer) { _ in
            let lvl = CGFloat(recorder.level)
            bars.removeFirst()
            let jitter = CGFloat.random(in: 0.5...1.1)
            bars.append(min(1, max(0.06, lvl * jitter)))
        }
    }
}
