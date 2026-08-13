import Foundation
import AppKit
import ApplicationServices

/// After a paste, watch the focused text field. If the user edits a word, auto-add
/// `old -> new` rules to the personal dictionary (Wispr-style auto-learn).
enum DictionaryLearner {
    private static let enabledKey = "autoAddDictionaryEnabled"
    private static var timer: Timer?
    private static var baseline = ""
    private static var pollsLeft = 0

    /// Default ON — matches “learn when I fix a word after paste.”
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Call right after paste with the exact text we inserted.
    static func watchAfterPaste(_ pasted: String) {
        timer?.invalidate()
        timer = nil
        guard isEnabled, AXIsProcessTrusted() else { return }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        baseline = trimmed
        pollsLeft = 40 // ~20s at 0.5s — enough to fix a typo, then stop

        // Let the paste settle into the field first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            startPolling()
        }
    }

    private static func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            pollsLeft -= 1
            if pollsLeft <= 0 {
                timer?.invalidate()
                timer = nil
                return
            }
            guard let current = focusedFieldValue() else { return }
            let cur = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cur.isEmpty, cur != baseline else { return }

            let added = CorrectionDictionary.shared.learn(from: baseline, to: cur)
            if !added.isEmpty {
                baseline = cur // don't re-learn the same edit
                let summary = added.map { "\($0.from) → \($0.to)" }.joined(separator: " · ")
                print("✅ Auto-dictionary: \(summary)")
                NotificationCenter.default.post(
                    name: .dictionaryAutoLearned,
                    object: nil,
                    userInfo: ["summary": summary]
                )
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private static func focusedFieldValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }

        let element = el as! AXUIElement
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let s = value as? String {
            return s
        }
        // Some apps expose selected text / AXStaticText differently — try selected text
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let s = selected as? String, !s.isEmpty {
            return s
        }
        return nil
    }
}

extension Notification.Name {
    static let dictionaryAutoLearned = Notification.Name("dictionaryAutoLearned")
}
