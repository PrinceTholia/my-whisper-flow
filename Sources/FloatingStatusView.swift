import SwiftUI

/// Floating overlay matching the approved pill preview (compact Flow-like capsule).
/// Fixed outer frame so NSHostingView inside NSPanel never renegotiates constraints.
struct FloatingStatusView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        ZStack {
            content
        }
        .frame(width: 200, height: 64)
        .animation(.easeInOut(duration: 0.18), value: controller.stage)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.stage {
        case .recording:
            RecordingPill(recorder: controller.recorder)
        case .transcribing:
            StatusPill(icon: "waveform", iconColor: Color.white.opacity(0.85),
                       text: "Transcribing…", spin: true)
        case .correcting:
            StatusPill(icon: "sparkles", iconColor: Color(red: 0.75, green: 0.7, blue: 1.0),
                       text: "Cleaning…", spin: true)
        case .done(let snippet):
            StatusPill(icon: "checkmark.circle.fill",
                       iconColor: Color(red: 0.45, green: 0.85, blue: 0.55),
                       text: snippet.isEmpty ? "Done" : snippet, spin: false)
        case .error(let msg):
            StatusPill(icon: "exclamationmark.triangle.fill",
                       iconColor: Color(red: 1.0, green: 0.72, blue: 0.35),
                       text: msg, spin: false)
        case .idle:
            Color.clear
        }
    }
}

/// Shared chrome from the HTML/mockup preview: frosted capsule, soft stroke, soft shadow.
private struct PillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                    )
            }
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 14, y: 8)
    }
}

/// Recording state from the approved preview: soft red mic + short white waveform.
struct RecordingPill: View {
    @ObservedObject var recorder: AudioRecorder
    @State private var bars: [CGFloat] = Array(repeating: 0.18, count: 16)
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private let micPink = Color(red: 1.0, green: 0.42, blue: 0.42) // #ff6b6b

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(micPink.opacity(0.22))
                    .frame(width: 26, height: 26)
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(micPink)
            }

            HStack(spacing: 2.5) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.45 + Double(bars[i]) * 0.5))
                        .frame(width: 2.5, height: max(5, bars[i] * 20))
                }
            }
            .frame(width: 96, height: 24, alignment: .center)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .modifier(PillChrome())
        .onReceive(timer) { _ in
            let lvl = CGFloat(recorder.level)
            bars.removeFirst()
            let jitter = CGFloat.random(in: 0.55...1.05)
            // Keep some motion even at low levels so the pill feels alive
            bars.append(min(1, max(0.12, max(lvl * jitter * 1.6, 0.15 + CGFloat.random(in: 0...0.2)))))
        }
    }
}

/// Same capsule chrome for transcribe / clean / done / error.
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
                    .tint(.white.opacity(0.9))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
            }

            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 148, maxWidth: 180, minHeight: 44, maxHeight: 44)
        .modifier(PillChrome())
    }
}
