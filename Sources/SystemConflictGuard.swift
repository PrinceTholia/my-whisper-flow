import Foundation
import AppKit

/// Prevents macOS built-in Dictation from stealing Fn double-tap.
///
/// When `AppleFnUsageType = 3` / Dictation shortcut = “Press Fn twice”, the system
/// shows live dictation text, pauses music, then clears the caret text when stopped —
/// which looks like Whisper “live translate then vanish until ⌘V”.
enum SystemConflictGuard {
    private static let alertedKey = "whisper.didAlertSystemFnDictation"

    /// Returns true if macOS still has Fn→Dictation enabled (conflicts with Whisper).
    static var isSystemFnDictationEnabled: Bool {
        let suite = UserDefaults(suiteName: "com.apple.HIToolbox")
        let fnUsage = intValue(suite?.object(forKey: "AppleFnUsageType"))
            ?? intValue(UserDefaults.standard.object(forKey: "AppleFnUsageType"))
            ?? readDefaultsInt("AppleFnUsageType")
        let dictationAuto = intValue(suite?.object(forKey: "AppleDictationAutoEnable"))
            ?? intValue(UserDefaults.standard.object(forKey: "AppleDictationAutoEnable"))
            ?? readDefaultsInt("AppleDictationAutoEnable")
        // 3 = Fn starts dictation; 1 = dictation auto-enable / Fn-twice shortcut active
        return fnUsage == 3 || dictationAuto == 1
    }

    /// Turn off system Fn→Dictation so Whisper owns the key. Safe every launch.
    @discardableResult
    static func disableSystemFnDictationIfNeeded(showAlertIfChanged: Bool = true) -> Bool {
        let wasEnabled = isSystemFnDictationEnabled
        applyDisable()

        if wasEnabled && showAlertIfChanged && !UserDefaults.standard.bool(forKey: alertedKey) {
            UserDefaults.standard.set(true, forKey: alertedKey)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "macOS Dictation was blocking Whisper"
                alert.informativeText = """
                Your Mac had “Press Fn twice” set for built-in Dictation. That pauses music, shows live system text, and fights Whisper paste.

                Whisper turned that shortcut off. If it comes back: System Settings → Keyboard → Dictation → Shortcut → Off.
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Dictation Settings")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    openDictationSettings()
                }
            }
        }
        return wasEnabled
    }

    static func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func applyDisable() {
        let suite = UserDefaults(suiteName: "com.apple.HIToolbox")
        suite?.set(0, forKey: "AppleFnUsageType")
        suite?.set(0, forKey: "AppleDictationAutoEnable")
        UserDefaults.standard.set(0, forKey: "AppleFnUsageType")
        UserDefaults.standard.set(0, forKey: "AppleDictationAutoEnable")

        runDefaultsWrite("AppleFnUsageType", "0")
        runDefaultsWrite("AppleDictationAutoEnable", "0")
        print("🛡️ Ensured system Fn→Dictation is off")
    }

    private static func runDefaultsWrite(_ key: String, _ value: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.HIToolbox", key, "-int", value]
        try? task.run()
        task.waitUntilExit()
    }

    private static func readDefaultsInt(_ key: String) -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.HIToolbox", key]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let v = Int(s) else { return nil }
        return v
    }

    private static func intValue(_ obj: Any?) -> Int? {
        if let i = obj as? Int { return i }
        if let n = obj as? NSNumber { return n.intValue }
        return nil
    }
}
