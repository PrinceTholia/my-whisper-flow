import Foundation

/// Transcribe audio via cloud STT — supports multiple providers via STTSettings.
class CloudTranscriptionService {
    private var provider: STTProvider { STTSettings.current }

    var isAvailable: Bool { STTSettings.key(for: provider) != nil }

    private func langCode(_ language: String, style: STTProvider.Style) -> String? {
        guard let lang = Languages.find(language) else { return nil }
        if lang.code == "auto" { return nil }
        return (style == .elevenlabs) ? lang.iso3 : lang.code
    }

    func transcribe(fileURL: URL, language: String,
                    completion: @escaping (Result<String, DictationAPIError>) -> Void) {
        let p = provider
        guard let key = STTSettings.key(for: p) else {
            completion(.failure(.noAPIKey(provider: p.name))); return
        }
        guard let endpoint = STTSettings.endpoint(for: p) else {
            completion(.failure(.network("Invalid endpoint"))); return
        }
        guard let fileData = try? Data(contentsOf: fileURL), !fileData.isEmpty else {
            completion(.failure(.emptyResponse)); return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120

        switch p.style {
        case .elevenlabs:
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openAI:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        let modelField = (p.style == .elevenlabs) ? "model_id" : "model"
        let langField  = (p.style == .elevenlabs) ? "language_code" : "language"

        field(modelField, STTSettings.model(for: p))
        if let lang = langCode(language, style: p.style) {
            field(langField, lang)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(.network(error.localizedDescription))); return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 0 {
                completion(.failure(.network("No response"))); return
            }
            if !(200...299).contains(status) {
                completion(.failure(.fromHTTP(status: status, data: data, headers: http?.allHeaderFields)))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.emptyResponse)); return
            }
            if let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(trimmed.isEmpty ? .failure(.emptyResponse) : .success(trimmed))
            } else {
                print("❌ \(p.name) response: \(json)")
                completion(.failure(.fromHTTP(status: status, data: data, headers: http?.allHeaderFields)))
            }
        }.resume()
    }
}
