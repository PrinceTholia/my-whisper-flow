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

/// Clipboard + auto-paste (known-good behavior).
///
/// Critical: never open System Settings during paste — that steals focus and
/// makes ⌘V land nowhere. Also: do not gate on `AXIsProcessTrusted()` alone;
/// ad-hoc builds often report false even when Accessibility is enabled.
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

    /// True when Accessibility APIs actually respond (stronger than AXIsProcessTrusted for ad-hoc).
    static var canUseAccessibilityAPIs: Bool {
        if AXIsProcessTrusted() { return true }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        // .apiDisabled means TCC denied this binary; anything else means APIs are usable
        return err != .apiDisabled
    }

    static var isAccessibilityTrusted: Bool { canUseAccessibilityAPIs }

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

        // Normal apps: NEVER open Settings here (steals focus).
        // NEVER skip paste because AXIsProcessTrusted() lied.
        // Do NOT activateIgnoringOtherApps — that breaks caret focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // 1) Prefer direct AX insert when APIs work
            if insertViaAccessibility(text) {
                print("✅ Paste via AX insert")
                return
            }
            // 2) Simulated ⌘V (needs Accessibility TCC for this binary)
            simulateCommandV()
            // 3) System Events backup after a beat (needs Automation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                _ = pasteViaSystemEvents(processName: target?.localizedName)
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
            if pasteViaSystemEvents(processName: processName) { return }
            simulateCommandV()
        }
    }

    @discardableResult
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return false }

        let el = focusedRef as! AXUIElement
        if AXUIElementSetAttributeValue(
            el, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success {
            return true
        }
        return false
    }

    @discardableResult
    private static func pasteViaMenu(processName: String) -> Bool {
        let escaped = escapeAppleScript(processName)
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
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }

    @discardableResult
    private static func pasteViaSystemEvents(processName: String?) -> Bool {
        let script: String
        if let processName {
            let escaped = escapeAppleScript(processName)
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

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

    /// Launch-only soft prompt — never during paste.
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
        if UserDefaults.standard.bool(forKey: didAttemptPromptKey) { return }
        UserDefaults.standard.set(true, forKey: didAttemptPromptKey)
        // Prompt dialog only — do not open System Settings window (steals focus later)
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
            if let err { print("⚠️ Automation warm-up: \(err)") }
        }
    }
}

extension Notification.Name {
    static let whisperNeedsAccessibilityForPaste = Notification.Name("whisperNeedsAccessibilityForPaste")
    static let whisperNeedsAutomationForPaste = Notification.Name("whisperNeedsAutomationForPaste")
}
