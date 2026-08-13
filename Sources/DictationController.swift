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
    case done(String)          // auto-pasted at caret
    case copied                // no caret — clipboard only; show ⌘V hint
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
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: Self.languageKey) }
    }

    private static let backtrackKey = "backtrackEnabled"
    private static let languageKey = "dictationLanguage"

    let recorder = AudioRecorder()
    private let whisper = WhisperService()
    private let cloud = CloudTranscriptionService()
    private let correction = TextCorrectionService()
    private var processing = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        useBacktrack = UserDefaults.standard.bool(forKey: Self.backtrackKey) // default false
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? "en"
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
                let final = CorrectionDictionary.shared.apply(to: text)
                let snippet = String(final.prefix(28))
                self.processing = false

                let outcome = Paster.paste(final)
                // Learner must run after delayed paste settles (not on optimistic return)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    DictionaryLearner.watchAfterPaste(final)
                }

                switch outcome {
                case .inserted:
                    self.status = "✅ Pasted"
                    self.stage = .done(snippet.isEmpty ? "Pasted" : snippet)
                case .copiedOnly:
                    if !Paster.isAccessibilityTrusted {
                        self.status = "Copied — enable Accessibility to auto-paste"
                        self.stage = .copied
                    } else {
                        self.status = "Copied — press ⌘V to paste"
                        self.stage = .copied
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + (outcome == .copiedOnly ? 2.8 : 1.0)) { [weak self] in
                    guard let self = self else { return }
                    if case .done = self.stage { self.stage = .idle }
                    if case .copied = self.stage { self.stage = .idle }
                }
            }
        }

        let failOnMain: (DictationAPIError) -> Void = { [weak self] err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.processing = false
                self.showAPIError(err)
            }
        }

        let afterSTT: (Result<String, DictationAPIError>) -> Void = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                failOnMain(err)
            case .success(let raw):
                let text = self.stripSoundAnnotations(raw)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failOnMain(.emptyResponse)
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
                    ) { corr in
                        switch corr {
                        case .success(let cleaned):
                            finishOnMain(cleaned)
                        case .failure(let err):
                            // Hard-fail on rate limits so the user sees the wait time.
                            // Soft-fail other cleanup errors: still paste the raw transcript.
                            if case .rateLimited = err {
                                failOnMain(err)
                            } else if case .http(let status, _, _) = err, status == 429 {
                                failOnMain(err)
                            } else {
                                print("⚠️ Correction failed (\(err.detailMessage)); pasting raw transcript")
                                finishOnMain(text)
                            }
                        }
                    }
                } else {
                    finishOnMain(text)
                }
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
            whisper.transcribe(fileURL: url) { result in
                if let result {
                    afterSTT(.success(result))
                } else {
                    afterSTT(.failure(.emptyResponse))
                }
            }
        }
    }

    /// Show a clear pill + tooltip; for rate limits, countdown so the user knows to wait.
    private func showAPIError(_ err: DictationAPIError) {
        status = err.detailMessage
        stage = .error(err.pillMessage)
        print("❌ Dictation: \(err.detailMessage)")

        // Countdown for rate limits
        if case .rateLimited(let sec, _) = err {
            var left = Int(ceil(sec))
            let token = UUID().uuidString
            statusItemToken = token
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                guard let self = self, self.statusItemToken == token else {
                    timer.invalidate(); return
                }
                left -= 1
                if left <= 0 {
                    timer.invalidate()
                    self.status = "Ready — try again"
                    self.stage = .idle
                    return
                }
                self.stage = .error("Rate limit — wait ~\(left)s")
                self.status = "Groq limit — please wait \(left)s, then dictate again"
            }
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        let hold = err.displaySeconds
        let msg = err.pillMessage
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self = self else { return }
            if case .error(let m) = self.stage, m == msg {
                self.stage = .idle
            }
        }
    }

    /// Cancels stale rate-limit timers when a new error arrives.
    private var statusItemToken: String? = nil

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
