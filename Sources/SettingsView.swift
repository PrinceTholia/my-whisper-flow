import SwiftUI

struct SettingsView: View {
    // Hotkey
    @State private var hotkeyConfig = HotkeyManager.shared.currentConfig
    @State private var isRecordingHotkey = false

    // Groq — single key used for both STT and AI correction
    @State private var groqKey = ""
    @State private var groqMsg = ""

    // Features
    @State private var backtrackOn = false
    @State private var soundOn = true
    @State private var autoDictOn = true

    private var sttProvider: STTProvider { STTRegistry.provider(id: "groq") }
    private var llmProvider: LLMProvider { LLMRegistry.provider(id: "groq") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Whisper Settings")
                    .font(.title3).bold()

                // ── Hotkey ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Global Hotkey", systemImage: "keyboard")
                        .font(.subheadline).bold()

                    HStack(spacing: 12) {
                        Text("Shortcut:").font(.caption)
                        HotkeyRecorderView(hotkey: $hotkeyConfig, isRecording: $isRecordingHotkey)
                            .frame(width: 180, height: 30)
                        Button(isRecordingHotkey ? "Listening…" : "Change") {
                            isRecordingHotkey.toggle()
                        }
                        .disabled(isRecordingHotkey)
                        Button("Reset") {
                            hotkeyConfig = .default
                            HotkeyManager.shared.updateConfig(hotkeyConfig)
                        }
                    }

                    Text("Hold Fn to talk · Double-tap Fn for hands-free (tap Fn again to stop)")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Hold to talk (press & hold to record, release to stop)", isOn: $hotkeyConfig.isHoldMode)
                        .font(.caption)
                        .onChange(of: hotkeyConfig.isHoldMode) { _ in
                            HotkeyManager.shared.updateConfig(hotkeyConfig)
                        }

                    Text("When hold is on: hold = push-to-talk, double-tap = hands-free. When off: double-tap starts, tap stops.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .onChange(of: hotkeyConfig.keyCode) { _ in HotkeyManager.shared.updateConfig(hotkeyConfig) }
                .onChange(of: hotkeyConfig.modifiers) { _ in HotkeyManager.shared.updateConfig(hotkeyConfig) }

                Divider()

                // ── Cleanup / feedback ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Dictation polish", systemImage: "wand.and.stars")
                        .font(.subheadline).bold()

                    Toggle("Backtrack (drop “sorry / actually…” self-corrections)", isOn: $backtrackOn)
                        .font(.caption)
                        .onChange(of: backtrackOn) { v in
                            UserDefaults.standard.set(v, forKey: "backtrackEnabled")
                        }

                    Text("Off by default. When on: “I want X, sorry, I want Y” pastes as “I want Y”. Needs AI Correction.")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Soft sound when recording starts/stops", isOn: $soundOn)
                        .font(.caption)
                        .onChange(of: soundOn) { v in FeedbackSound.isEnabled = v }

                    Text("Custom soft pips (not Wispr’s sounds). Toggle off if you prefer silence.")
                        .font(.caption2).foregroundColor(.secondary)

                    Toggle("Auto-add edits to Dictionary", isOn: $autoDictOn)
                        .font(.caption)
                        .onChange(of: autoDictOn) { v in DictionaryLearner.isEnabled = v }

                    Text("After paste, if you fix a word in the text field, that correction is learned automatically (needs Accessibility).")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Divider()

                // ── Groq (STT + AI correction) ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("Groq API Key", systemImage: "key.fill")
                        .font(.subheadline).bold()

                    Text("Used for both transcription (\(sttProvider.defaultModel)) and AI correction (\(llmProvider.defaultModel))")
                        .font(.caption).foregroundColor(.secondary)

                    SecureField("gsk_…", text: $groqKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save") { saveKey() }.buttonStyle(.borderedProminent)
                        Button("Test") { testKey() }
                        if !groqMsg.isEmpty { Text(groqMsg).font(.caption) }
                    }

                    Text("Get a free key at console.groq.com · Or set GROQ_API_KEY in ~/.zshrc to skip entering a key")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Text("💡 Fix words the STT keeps mis-transcribing via menu → Dictionary…")
                    .font(.caption2).foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 460, height: 520)
        .onAppear {
            loadKey()
            backtrackOn = UserDefaults.standard.bool(forKey: "backtrackEnabled")
            soundOn = FeedbackSound.isEnabled
            autoDictOn = DictionaryLearner.isEnabled
        }
    }

    // MARK: Groq key (shared by STT + LLM)
    private func loadKey() {
        groqKey = STTSettings.savedKeyFile(for: sttProvider)
        if groqKey.isEmpty {
            groqKey = (try? String(contentsOfFile: KeyStore.dir + "/llm_groq.key", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func applyKey() {
        STTSettings.providerID = "groq"
        LLMSettings.providerID = "groq"
        let t = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            STTSettings.saveKey(t, for: sttProvider)
            LLMSettings.saveKey(t, for: llmProvider)
        }
    }

    private func saveKey() {
        applyKey()
        groqMsg = "✅ Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { groqMsg = "" }
    }

    private func testKey() {
        applyKey()
        guard STTSettings.key(for: sttProvider) != nil else { groqMsg = "⚠️ Enter API key first"; return }

        groqMsg = "⏳ Testing…"
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(STTSettings.key(for: sttProvider)!)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                groqMsg = code == 200 ? "✅ Key is valid" : "❌ Invalid key (code \(code))"
            }
        }.resume()
    }
}
