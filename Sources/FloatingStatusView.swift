import SwiftUI

/// Compact floating overlay — small pill + live waveform (closer to Wispr Flow’s bar).
/// Fixed frame so NSHostingView inside NSPanel never renegotiates constraints mid-stage.
struct FloatingStatusView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ZStack {
            content
        }
        .frame(width: 220, height: 56)
        .animation(.easeInOut(duration: 0.18), value: controller.stage)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .recording:
            RecordingPill(recorder: controller.recorder)
        case .transcribing:
            StatusPill(icon: "waveform", iconColor: .cyan, text: "Transcribing…", spin: true)
        case .correcting:
            StatusPill(icon: "sparkles", iconColor: Color(red: 0.55, green: 0.45, blue: 0.95),
                       text: "Cleaning…", spin: true)
        case .done(let snippet):
            StatusPill(icon: "checkmark.circle.fill", iconColor: .green,
                       text: snippet.isEmpty ? "Done" : snippet, spin: false)
        case .error(let msg):
            StatusPill(icon: "exclamationmark.triangle.fill", iconColor: .orange,
                       text: msg, spin: false)
        case .idle:
            Color.clear
        }
    }
}

/// Compact recording state: mic + short waveform inside one capsule.
struct RecordingPill: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var bars: [CGFloat] = Array(repeating: 0.12, count: 16)
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 26, height: 26)
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
            }

            HStack(spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(Color.primary.opacity(0.55 + Double(bars[i]) * 0.35))
                        .frame(width: 2.5, height: max(4, bars[i] * 22))
                }
            }
            .frame(width: 90, height: 24, alignment: .center)
        }
        .frame(width: 160, height: 36, alignment: .center)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .onReceive(timer) { _ in
            let lvl = CGFloat(recorder.level)
            bars.removeFirst()
            let jitter = CGFloat.random(in: 0.55...1.05)
            bars.append(min(1, max(0.08, lvl * jitter * 1.4)))
        }
    }
}

/// Pill-shaped status indicator: icon + optional spinner + label
struct StatusPill: View {
    let icon: String
    let iconColor: Color
    let text: String
    let spin: Bool

    var body: some View {
        HStack(spacing: 8) {
            if spin {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
            }

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: 180, height: 36, alignment: .center)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}
