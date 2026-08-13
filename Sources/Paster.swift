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
    /// Accessibility trusted — simulated ⌘V was scheduled.
    case inserted
    /// Clipboard only (no AX trust, or no valid target). User may need ⌘V / Fix Accessibility.
    case copiedOnly
}

/// Clipboard + paste.
/// Normal apps: never activateIgnoringOtherApps. Prefer simulated ⌘V when AX is trusted.
/// When AX is off: clipboard + System Events only, and report `.copiedOnly` honestly.
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
    private static let didAttemptPromptKey = "whisper.didAttemptAXPrompt"
    private static let exeTokenKey = "whisper.executableToken"
    private static var didNudgeAXThisSession = false
    private static var didNudgeAutomationThisSession = false

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

        let axTrusted = AXIsProcessTrusted()
        if !axTrusted {
            nudgeAccessibilityIfNeeded()
        }

        if isTerminalApp(target) {
            pasteIntoTerminal(app: target, axTrusted: axTrusted)
            return axTrusted ? .inserted : .copiedOnly
        }

        // Normal apps — do NOT activateIgnoringOtherApps (breaks caret / paste).
        if axTrusted {
            // HID ⌘V only — avoid System Events double-insert when both succeed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                simulateCommandV()
            }
            return .inserted
        }

        // AX off: still try Automation (System Events); UI must not claim "Pasted"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if !pasteViaSystemEvents(processName: nil) {
                nudgeAutomationIfNeeded()
            }
        }
        return .copiedOnly
    }

    private static func nudgeAccessibilityIfNeeded() {
        guard !didNudgeAXThisSession else { return }
        didNudgeAXThisSession = true
        NotificationCenter.default.post(name: .whisperNeedsAccessibilityForPaste, object: nil)
    }

    private static func nudgeAutomationIfNeeded() {
        guard !didNudgeAutomationThisSession else { return }
        didNudgeAutomationThisSession = true
        NotificationCenter.default.post(name: .whisperNeedsAutomationForPaste, object: nil)
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

    private static func pasteIntoTerminal(app: NSRunningApplication?, axTrusted: Bool) {
        let processName = app?.localizedName ?? "Terminal"
        app?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if pasteViaMenu(processName: processName) { return }
            if pasteViaSystemEvents(processName: processName) { return }
            if axTrusted {
                simulateCommandV()
            } else {
                nudgeAutomationIfNeeded()
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
        if err != nil {
            print("⚠️ System Events menu paste: \(err!)")
            return false
        }
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

    @discardableResult
    private static func pasteViaSystemEvents(processName: String?) -> Bool {
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
        if let err {
            print("⚠️ System Events paste: \(err)")
            return false
        }
        return true
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

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

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
            UserDefaults.standard.set(false, forKey: didAttemptPromptKey)
        }
        promptAccessibilityOnce()
    }

    static func promptAccessibilityOnce() {
        if AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: didPromptKey)
            return
        }
        // One attempt per binary — do not mark "granted" unless trusted
        if UserDefaults.standard.bool(forKey: didAttemptPromptKey) { return }
        UserDefaults.standard.set(true, forKey: didAttemptPromptKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: didPromptKey)
        }
    }

    static func warmAutomationPermission() {
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: """
            tell application "System Events"
              return name of first process whose frontmost is true
            end tell
            """)?.executeAndReturnError(&err)
            if err != nil {
                DispatchQueue.main.async { nudgeAutomationIfNeeded() }
            }
        }
    }
}

extension Notification.Name {
    static let whisperNeedsAccessibilityForPaste = Notification.Name("whisperNeedsAccessibilityForPaste")
    static let whisperNeedsAutomationForPaste = Notification.Name("whisperNeedsAutomationForPaste")
}
