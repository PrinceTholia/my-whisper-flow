import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Remembers which app had focus when dictation started (for Terminal restore only).
enum FocusMemory {
    private static var app: NSRunningApplication?

    static func capture() {
        app = NSWorkspace.shared.frontmostApplication
    }

    static var current: NSRunningApplication? { app }
}

enum PasteOutcome: Equatable {
    case inserted
    case copiedOnly
}

/// Clipboard + paste — restored from the known-good path (commit 374740b).
/// Normal apps: never activateIgnoringOtherApps (that broke paste). Just ⌘V.
/// Terminals: activate + Edit→Paste / System Events.
enum Paster {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.github.wez.wezterm",
        "org.alacritty",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]

    private static let didPromptKey = "whisper.didPromptAccessibility"
    private static let exeTokenKey = "whisper.executableToken"

    @discardableResult
    static func paste(_ text: String) -> PasteOutcome {
        guard !text.isEmpty else { return .copiedOnly }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let target = FocusMemory.current
        if target?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return .copiedOnly
        }

        if isTerminalApp(target) {
            pasteIntoTerminal(app: target)
            return .inserted
        }

        // Normal apps (Notes, Slack, Cursor, browsers…):
        // Do NOT call activateIgnoringOtherApps — that breaks paste.
        // Do NOT gate on caret detection — Electron apps fail that check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulateCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pasteViaSystemEvents(processName: nil)
            }
        }
        return .inserted
    }

    private static func isTerminalApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        if terminalBundleIDs.contains(id) { return true }
        let name = (app?.localizedName ?? "").lowercased()
        return name.contains("terminal") || name.contains("iterm")
            || name.contains("kitty") || name.contains("warp")
            || name.contains("alacritty") || name.contains("ghostty")
            || name.contains("wezterm") || name.contains("hyper")
    }

    private static func pasteIntoTerminal(app: NSRunningApplication?) {
        let processName = app?.localizedName ?? "Terminal"
        app?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if pasteViaMenu(processName: processName) { return }
            pasteViaSystemEvents(processName: processName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                simulateCommandV()
            }
        }
    }

    @discardableResult
    private static func pasteViaMenu(processName: String) -> Bool {
        let escaped = processName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
          tell process "\(escaped)"
            try
              click menu item "Paste" of menu "Edit" of menu bar 1
              return "ok"
            end try
            try
              keystroke "v" using command down
              return "ok"
            end try
          end tell
        end tell
        return "fail"
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { return false }
        return result?.stringValue == "ok"
    }

    private static func simulateCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func pasteViaSystemEvents(processName: String?) {
        let script: String
        if let processName {
            let escaped = processName
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            tell application "System Events"
              tell process "\(escaped)"
                set frontmost to true
                keystroke "v" using command down
              end tell
            end tell
            """
        } else {
            script = """
            tell application "System Events"
              keystroke "v" using command down
            end tell
            """
        }
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { print("⚠️ System Events paste: \(err)") }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// New binary → Accessibility grant may not apply. Re-prompt once per binary.
    static func refreshTrustPromptIfBinaryChanged() {
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            promptAccessibilityOnce()
            return
        }
        let token = "\(modified.timeIntervalSince1970)-\(size)"
        if UserDefaults.standard.string(forKey: exeTokenKey) != token {
            UserDefaults.standard.set(token, forKey: exeTokenKey)
            UserDefaults.standard.set(false, forKey: didPromptKey)
        }
        promptAccessibilityOnce()
    }

    static func promptAccessibilityOnce() {
        if UserDefaults.standard.bool(forKey: didPromptKey) { return }
        UserDefaults.standard.set(true, forKey: didPromptKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func warmAutomationPermission() {
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: """
            tell application "System Events"
              return name of first process whose frontmost is true
            end tell
            """)?.executeAndReturnError(&err)
        }
    }
}

extension Notification.Name {
    static let whisperNeedsAccessibilityForPaste = Notification.Name("whisperNeedsAccessibilityForPaste")
}
