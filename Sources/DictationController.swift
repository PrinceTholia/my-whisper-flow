import Foundation
import AppKit
import Combine
import Carbon.HIToolbox
import ApplicationServices

/// Visual processing stage — drives the floating status overlay
enum Stage: Equatable {
    case idle
    case recording
    case transcribing
    case correcting
    case done(String)
    case error(String)
}

/// Orchestrates everything: record → transcribe (cloud/local) → correct (LLM) → paste into focused app
class DictationController: ObservableObject {
    @Published var isRecording = false
    @Published var status = ""
    @Published var stage: Stage = .idle
    @Published var useCloudSTT = true
    @Published var useCorrection = true
    /// Wispr-style Backtrack: drop false starts / “sorry, I meant…” restatements. Default OFF.
    @Published var useBacktrack: Bool {
        didSet { UserDefaults.standard.set(useBacktrack, forKey: Self.backtrackKey) }
    }
    @Published var language = "th"

    private static let backtrackKey = "backtrackEnabled"

    let recorder = AudioRecorder()
    private let whisper = WhisperService()
    private let cloud = CloudTranscriptionService()
    private let correction = TextCorrectionService()
    private var processing = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        useBacktrack = UserDefaults.standard.bool(forKey: Self.backtrackKey) // default false
        recorder.$recordedFileURL
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.handleAudio(url) }
            .store(in: &cancellables)
    }

    func toggle() { recorder.isRecording ? stop() : start() }

    func start() {
        guard !processing, !recorder.isRecording else { return }
        FocusMemory.capture()
        recorder.startRecording()
        isRecording = recorder.isRecording
        if isRecording {
            FeedbackSound.playStart()
            status = "Listening…"
            stage = .recording
        } else {
            status = "❌ Microphone unavailable"
            stage = .error("Microphone unavailable")
        }
    }

    func stop() {
        guard recorder.isRecording else { return }
        FeedbackSound.playStop()
        recorder.stopRecording()
        isRecording = false
        status = "⏳ Processing…"
        stage = .transcribing
    }

    private func handleAudio(_ url: URL) {
        processing = true
        let lang = language

        let finishOnMain: (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // แม้ correction ปิดอยู่ หรือ LLM มองข้ามคำเฉพาะ ก็ให้ dictionary เป็นเจ้าบทบาทสุดท้าย
                let final = CorrectionDictionary.shared.apply(to: text)
                let snippet = String(final.prefix(28))
                self.status = "✅ " + snippet
                // Hide overlay before paste so the target field keeps focus
                self.stage = .idle
                self.processing = false
                Paster.paste(final)
                DictionaryLearner.watchAfterPaste(final)
                // Brief confirmation via tooltip only (no blocking overlay)
                self.status = "✅ Pasted: " + snippet
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self = self else { return }
                    if self.status.hasPrefix("✅") { self.status = "" }
                }
            }
        }

        let afterSTT: (String?) -> Void = { [weak self] result in
            guard let self = self else { return }
            // ลบคำบรรยายเสียง/เหตุการณ์ที่ STT เติมมา เช่น (เสียงลม) (wind) [background noise]
            let text = (result.map { self.stripSoundAnnotations($0) }) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async {
                    self.status = "⚠️ No audio detected"
                    self.stage = .error("No audio detected")
                    self.processing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        if self?.stage == .error("No audio detected") { self?.stage = .idle }
                    }
                }
                return
            }
            if self.useCorrection {
                DispatchQueue.main.async {
                    self.status = "✨ AI correction…"
                    self.stage = .correcting
                }
                self.correction.correct(
                    text: text,
                    language: lang,
                    backtrack: UserDefaults.standard.bool(forKey: Self.backtrackKey)
                ) { corrected in
                    finishOnMain(corrected ?? text)
                }
            } else {
                finishOnMain(text)
            }
        }

        DispatchQueue.main.async {
            self.status = self.useCloudSTT ? "☁️ Transcribing…" : "📝 Transcribing…"
            self.stage = .transcribing
        }

        if useCloudSTT {
            cloud.transcribe(fileURL: url, language: lang) { result in
                try? FileManager.default.removeItem(at: url)
                afterSTT(result)
            }
        } else {
            whisper.language = lang
            whisper.transcribe(fileURL: url) { result in afterSTT(result) }
        }
    }

    /// ลบคำบรรยายเสียง/เหตุการณ์ที่ STT ใส่มา เช่น (เสียงลม) (wind noise) [applause] *laughs*
    /// แบบที่ ElevenLabs Scribe และ Whisper มักแทรกเข้ามา
    private func stripSoundAnnotations(_ text: String) -> String {
        var result = text
        let patterns = [
            "\\([^\\)]*\\)",   // ( ... )   ASCII
            "（[^）]*）",         // （ ... ） fullwidth
            "\\[[^\\]]*\\]",   // [ ... ]
            "【[^】]*】",         // 【 ... 】
            "\\*[^*]*\\*",      // * ... *
            "‹[^›]*›",           // ‹ ... ›
            "«[^»]*»",          // « ... »
        ]
        for p in patterns {
            result = result.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        // กรณีคำบรรยายไม่มีวงเล็บปิด (เช่น "(เสียงลม" ค้าง) ลบคำที่ขึ้นต้นด้วย "เสียง" ที่ค้าง
        // ยุบช่องว่างซ้อน และตัดปีกกะไร
        result = result
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
