import Foundation
import AppKit

/// Prevents macOS built-in Dictation from stealing Fn double-tap.
///
/// When `AppleFnUsageType = 3` / Dictation shortcut = “Press Fn twice”, the system
/// shows live dictation text, pauses music, then clears the caret text when stopped —
/// which looks like Whisper “live translate then vanish until ⌘V”.
enum SystemConflictGuard {
    private static let appliedKey = "whisper.didDisableSystemFnDictation"

    /// Turn off system Fn→Dictation so Whisper owns the key. Safe to call every launch.
    static func disableSystemFnDictationIfNeeded() {
        let suite = UserDefaults(suiteName: "com.apple.HIToolbox")
        let fnUsage = suite?.object(forKey: "AppleFnUsageType") as? Int
            ?? UserDefaults.standard.object(forKey: "AppleFnUsageType") as? Int
        let dictationAuto = suite?.object(forKey: "AppleDictationAutoEnable") as? Int
            ?? UserDefaults.standard.object(forKey: "AppleDictationAutoEnable") as? Int

        // 3 = start dictation; we need Fn free for Whisper
        let conflicts = (fnUsage == 3) || (dictationAuto == 1)
        guard conflicts || !UserDefaults.standard.bool(forKey: appliedKey) else { return }

        // Fn does nothing at the system level (Whisper still sees flagsChanged)
        suite?.set(0, forKey: "AppleFnUsageType")
        UserDefaults.standard.set(0, forKey: "AppleFnUsageType")

        // Don't auto-enable / prompt for system Dictation on Fn
        suite?.set(0, forKey: "AppleDictationAutoEnable")
        UserDefaults.standard.set(0, forKey: "AppleDictationAutoEnable")

        // Also write via `defaults` domain for persistence across apps
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
        try? task.run()
        task.waitUntilExit()

        let task2 = Process()
        task2.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task2.arguments = ["write", "com.apple.HIToolbox", "AppleDictationAutoEnable", "-int", "0"]
        try? task2.run()
        task2.waitUntilExit()

        UserDefaults.standard.set(true, forKey: appliedKey)
        print("🛡️ Disabled system Fn→Dictation conflict (AppleFnUsageType=0)")
    }
}
