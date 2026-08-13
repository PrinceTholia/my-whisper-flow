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

/// Clipboard + paste. Keep the simple path for normal apps (what worked before);
/// only Terminals get the special activate + Edit→Paste flow.
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

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let target = FocusMemory.current
        if isTerminalApp(target) {
            pasteIntoTerminal(app: target)
            return
        }

        // Normal apps (Notes, Slack, Cursor, browsers…):
        // Do NOT call activateIgnoringOtherApps — that was breaking paste everywhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulateCommandV()
            // Backup if ⌘V was ignored
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pasteViaSystemEvents(processName: nil)
            }
        }
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
        // Bring terminal back (Fn release can leave focus elsewhere), then Paste
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
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func promptAccessibilityOnce() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
    }
}
