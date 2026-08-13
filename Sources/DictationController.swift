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
                self.stage = .done(snippet)
                self.processing = false
                Paster.paste(final)
                DictionaryLearner.watchAfterPaste(final)
                // กลับเป็น idle หลังโชว์สักครู่
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self = self else { return }
                    if self.stage == .done(snippet) { self.stage = .idle }
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

/// Copy text to clipboard and insert into the focused app.
/// Prefers Accessibility selected-text insert; falls back to ⌘V.
/// Requires Accessibility — after ad-hoc rebuilds macOS often drops trust until re-enabled.
enum Paster {
    private static var didPrompt = false

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            // Don't spam the system prompt mid-dictation; nudge once per session.
            promptAccessibilityOnce()
            print("⚠️ Accessibility off — text left on clipboard (⌘V to paste)")
            NotificationCenter.default.post(
                name: .whisperPasteNeedsAccessibility,
                object: nil
            )
            return
        }

        // Let the target app regain focus after hotkey release / overlay hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if insertViaAccessibility(text) { return }
            simulateCommandV()
        }
    }

    /// Best path: replace selected text (or insert at caret) via AX — works when ⌘V is flaky.
    @discardableResult
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return false }

        let el = focusedRef as! AXUIElement

        // 1) Replace selection / insert at caret (preferred)
        if AXUIElementSetAttributeValue(
            el, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success {
            return true
        }

        // 2) Some fields only expose AXValue — append/replace whole value carefully
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
           let existing = valueRef as? String {
            var rangeRef: CFTypeRef?
            var insertion = existing + text
            if AXUIElementCopyAttributeValue(
                el, kAXSelectedTextRangeAttribute as CFString, &rangeRef
            ) == .success,
               let range = rangeRef,
               CFGetTypeID(range) == AXValueGetTypeID() {
                var cfRange = CFRange()
                if AXValueGetValue(range as! AXValue, .cfRange, &cfRange),
                   cfRange.location >= 0,
                   cfRange.location <= existing.utf16.count {
                    let start = existing.utf16.index(
                        existing.utf16.startIndex,
                        offsetBy: cfRange.location,
                        limitedBy: existing.utf16.endIndex
                    ) ?? existing.utf16.endIndex
                    let endOffset = min(cfRange.location + max(cfRange.length, 0), existing.utf16.count)
                    let end = existing.utf16.index(
                        existing.utf16.startIndex,
                        offsetBy: endOffset,
                        limitedBy: existing.utf16.endIndex
                    ) ?? existing.utf16.endIndex
                    let startS = String.Index(start, within: existing) ?? existing.endIndex
                    let endS = String.Index(end, within: existing) ?? existing.endIndex
                    insertion = existing.replacingCharacters(in: startS..<endS, with: text)
                }
            }
            if AXUIElementSetAttributeValue(
                el, kAXValueAttribute as CFString, insertion as CFTypeRef
            ) == .success {
                return true
            }
        }

        return false
    }

    private static func simulateCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // hid tap first; session tap as backup for some sandboxed targets
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// Prompt until trusted (safe to call repeatedly; system dialog only when needed).
    static func promptAccessibilityOnce() {
        if AXIsProcessTrusted() { return }
        // Allow a fresh prompt after rebuilds / each cold launch
        if didPrompt { return }
        didPrompt = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Also jump to the Accessibility pane so the user can flip Whisper on
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func resetPromptFlag() { didPrompt = false }
}

extension Notification.Name {
    static let whisperPasteNeedsAccessibility = Notification.Name("whisperPasteNeedsAccessibility")
}
