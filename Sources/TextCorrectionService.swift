import Foundation

/// Send raw transcription text to LLM (cloud) to fix typos, punctuation, and sentence structure.
/// Supports multiple providers (DeepSeek, OpenAI, Groq, OpenRouter, Gemini, Anthropic, Custom)
/// via LLMSettings — see LLMProvider.swift
class TextCorrectionService: ObservableObject {
    @Published var isEnabled = true
    @Published var isCorrecting = false

    private var provider: LLMProvider { LLMSettings.current }
    private var apiKey: String? { LLMSettings.key(for: provider) }

    var isAvailable: Bool { apiKey != nil }

    func correct(text: String, language: String, backtrack: Bool = false,
                 completion: @escaping (String?) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(nil); return
        }
        let p = provider
        guard let key = LLMSettings.key(for: p) else {
            print("❌ No key found for \(p.name) (configure in Settings or set env \(p.envKey))")
            completion(nil); return
        }

        let langHint: String
        if language == "auto" {
            langHint = "The text may be in any language — keep the original language"
        } else if let name = Languages.find(language)?.name {
            langHint = "The text is in \(name)"
        } else {
            langHint = "The text may be in any language — keep the original language"
        }

        var systemPrompt = """
        You are a text correction assistant for speech-to-text output, which often contains
        misheard words and missing punctuation.
        Your tasks:
        - Fix misheard/garbled words based on context
        - Add punctuation and spacing to improve readability
        - Do NOT add new content, summarize, translate, or change word endings/speaker gender
        - Return ONLY the corrected text — no explanations, no quotation marks
        \(langHint)
        """

        if backtrack {
            systemPrompt += """


            BACKTRACK (enabled): The speaker may correct themselves mid-utterance.
            Keep only the FINAL intended meaning. Drop abandoned phrases, false starts,
            and correction markers such as "sorry", "actually", "I mean", "scratch that",
            "no wait", "wait", or a full restatement that replaces an earlier clause.
            Example input: "I want to create something new, sorry, I want to make something that was not mentioned."
            Example output: "I want to make something that was not mentioned."
            Do NOT remove the word "actually" when it is part of meaning
            (e.g. "I actually enjoyed it" stays intact).
            """
        }

        // User's own known corrections — helps with proper nouns / brand names the model
        // wouldn't otherwise know. (A deterministic pass also runs before paste, so exact
        // matches always land even if the model ignores this.)
        let hint = CorrectionDictionary.shared.hintForPrompt
        if !hint.isEmpty {
            systemPrompt += "\n\nThe user's own known corrections for their speech — apply these where the meaning matches:\n" + hint
        }

        let endpoint = LLMSettings.endpoint(for: p)
        let model = LLMSettings.model(for: p)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body: [String: Any]
        switch p.style {
        case .openAI:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": text],
                ],
            ]
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var anthropicBody: [String: Any] = [
                "model": model,
                "max_tokens": 8192,
                "temperature": 0.2,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": text],
                ],
            ]
            // GLM-5 enables thinking by default → disable for fast text correction
            if model.lowercased().contains("glm") {
                anthropicBody["thinking"] = ["type": "disabled"]
            }
            body = anthropicBody
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil); return
        }
        req.httpBody = httpBody

        DispatchQueue.main.async { self.isCorrecting = true }

        let style = p.style
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.isCorrecting = false }

            if let error = error {
                print("❌ Correction error: \(error.localizedDescription)")
                completion(nil); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("❌ Correction: could not parse response")
                completion(nil); return
            }

            let content = Self.extractText(from: json, style: style)
            guard let raw = content else {
                print("❌ Correction response: \(json)")
                completion(nil); return
            }

            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            completion(cleaned.isEmpty ? nil : cleaned)
        }.resume()
    }

    /// Extract text from the response based on the provider's API style
    private static func extractText(from json: [String: Any], style: LLMProvider.Style) -> String? {
        switch style {
        case .openAI:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return content
        case .anthropic:
            guard let content = json["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined()
        }
    }
}
