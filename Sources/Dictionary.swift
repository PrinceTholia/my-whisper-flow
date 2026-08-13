import Foundation

/// User-maintained find→replace dictionary for words the STT keeps mis-transcribing.
///
/// Backed by a plain-text file at `~/.whisperapp/dictionary.txt`:
///
///     # one rule per line:  wrong -> right      (# = comment)
///     เกมส์ -> Game
///     gamezxz -> Gamezxz
///     บิทคอย -> Bitcoin
///
/// Used two ways:
///  - `hintForPrompt`: appended to the LLM correction system prompt so it knows the
///    user's own terms (handles fuzzy/garbled cases the deterministic pass can't).
///  - `apply(to:)`:    deterministic phrase replace as the final pass before paste,
///    guaranteeing the user's certain corrections always land — even with correction off.
///
/// Matching rules:
///  - `from` is pure ASCII  → `\b`-bounded, case-insensitive regex (English proper nouns).
///  - `from` has non-ASCII  → exact substring, case-sensitive (Thai has no word boundaries).
/// Rules apply in file order.
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private struct Rule { let from: String; let to: String; let isASCII: Bool }

    private static var path: String { KeyStore.dir + "/dictionary.txt" }

    private var rules: [Rule] = []
    private var lastMtime: Date? = nil
    private let lock = NSLock()

    private init() { reload(force: true) }

    // MARK: - Loading (reloads only when the file's mtime changes)

    private func reload(force: Bool) {
        let path = Self.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date
        if !force, mtime == lastMtime { return }
        lastMtime = mtime

        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        rules = Self.parse(raw)
    }

    private static func parse(_ raw: String) -> [Rule] {
        var out: [Rule] = []
        out.reserveCapacity(64)
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let arrow = trimmed.range(of: "->") else { continue }
            let from = String(trimmed[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let to   = String(trimmed[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            if from.isEmpty || to.isEmpty { continue }
            let isASCII = from.unicodeScalars.allSatisfy { $0.isASCII }
            out.append(Rule(from: from, to: to, isASCII: isASCII))
        }
        return out
    }

    private func snapshot() -> [Rule] {
        lock.lock(); reload(force: false); let r = rules; lock.unlock()
        return r
    }

    // MARK: - Public

    /// Append a rule and persist. Skips empty / identical / duplicate rules.
    @discardableResult
    func addRule(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty, f != t else { return false }

        lock.lock()
        defer { lock.unlock() }
        reload(force: true)
        if rules.contains(where: { $0.from.caseInsensitiveCompare(f) == .orderedSame && $0.to == t }) {
            return false
        }
        let isASCII = f.unicodeScalars.allSatisfy { $0.isASCII }
        rules.append(Rule(from: f, to: t, isASCII: isASCII))
        persistLocked()
        return true
    }

    /// Compare pasted text vs user-edited text; add one rule per changed token.
    /// Returns the rules that were newly added.
    @discardableResult
    func learn(from original: String, to edited: String) -> [(from: String, to: String)] {
        let a = tokenize(original)
        let b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        var pairs: [(String, String)] = []
        if a.count == b.count {
            for i in 0..<a.count where a[i] != b[i] {
                // Only learn word-like tokens (skip pure punctuation)
                if looksLearnable(a[i]), looksLearnable(b[i]) {
                    pairs.append((a[i], b[i]))
                }
            }
        } else {
            // Single substitution heuristic: one token removed, one added
            let setA = Set(a)
            let setB = Set(b)
            let removed = a.filter { !setB.contains($0) }
            let added = b.filter { !setA.contains($0) }
            if removed.count == 1, added.count == 1,
               looksLearnable(removed[0]), looksLearnable(added[0]) {
                pairs.append((removed[0], added[0]))
            }
        }

        var added: [(from: String, to: String)] = []
        for (f, t) in pairs {
            if addRule(from: f, to: t) {
                added.append((f, t))
            }
        }
        return added
    }

    private func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    private func looksLearnable(_ token: String) -> Bool {
        let stripped = token.trimmingCharacters(in: .punctuationCharacters)
        return stripped.count >= 2
    }

    private func persistLocked() {
        let text = rules.map { "\($0.from) -> \($0.to)" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(atPath: KeyStore.dir, withIntermediateDirectories: true)
        try? text.write(toFile: Self.path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: Self.path)
        lastMtime = Date()
    }

    /// Deterministic replacement applied to the final text before paste.
    func apply(to text: String) -> String {
        let active = snapshot()
        guard !active.isEmpty else { return text }
        var result = text
        for r in active {
            if r.isASCII {
                // word-boundary, case-insensitive (escape both pattern & replacement template)
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: r.from) + "\\b"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                let template = NSRegularExpression.escapedTemplate(for: r.to)
                result = re.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            } else {
                // Thai / mixed: exact substring, case-sensitive
                result = result.replacingOccurrences(of: r.from, with: r.to)
            }
        }
        return result
    }

    /// Hint appended to the LLM correction prompt. Empty string when there are no rules.
    var hintForPrompt: String {
        let active = snapshot()
        guard !active.isEmpty else { return "" }
        return active.map { "- \($0.from) → \($0.to)" }.joined(separator: "\n")
    }
}
