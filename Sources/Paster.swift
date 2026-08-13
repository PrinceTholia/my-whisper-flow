import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Remembers which app had focus when dictation started.
enum FocusMemory {
    private static var app: NSRunningApplication?

    static func capture() {
        app = NSWorkspace.shared.frontmostApplication
    }

    static var current: NSRunningApplication? { app }
}

/// Fully automatic paste — user should never need to press ⌘V.
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

    private static var didNudgeAccessibility = false

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }

        // Always leave text on clipboard as last-resort safety net (not the primary UX)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let target = FocusMemory.current
        let terminal = isTerminalApp(target)

        if terminal {
            target?.activate(options: [.activateIgnoringOtherApps])
        }

        let delay: TimeInterval = terminal ? 0.30 : 0.10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 1) Direct Accessibility insert at caret (true auto-paste, no keys)
            if insertViaAccessibility(text) {
                print("✅ Auto-paste via Accessibility")
                return
            }

            // 2) Type the characters directly (no ⌘V) — works in many apps + Terminal
            if typeTextDirectly(text) {
                print("✅ Auto-paste via direct typing")
                return
            }

            // 3) Terminal Edit → Paste menu
            if terminal, let name = target?.localizedName, pasteViaMenu(processName: name) {
                print("✅ Auto-paste via Terminal menu")
                return
            }

            // 4) Silent ⌘V simulation (backup only — still automatic)
            simulateCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if terminal, let name = target?.localizedName {
                    pasteViaSystemEvents(processName: name)
                } else {
                    pasteViaSystemEvents(processName: nil)
                }
            }

            // If Accessibility is off, synthetic input often fails — nudge once
            if !AXIsProcessTrusted(), !didNudgeAccessibility {
                didNudgeAccessibility = true
                NotificationCenter.default.post(name: .whisperNeedsAccessibilityForPaste, object: nil)
            }
        }
    }

    // MARK: - Strategies

    /// Insert/replace at the focused field caret — no keyboard events.
    @discardableResult
    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return false }

        let el = focusedRef as! AXUIElement

        // Preferred: replace selection / insert at caret
        let setSelected = AXUIElementSetAttributeValue(
            el, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if setSelected == .success { return true }

        // Fallback: splice into AXValue at selected range
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
              let existing = valueRef as? String else { return false }

        var insertion = existing + text
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            el, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success,
           let range = rangeRef,
           CFGetTypeID(range) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange),
               cfRange.location >= 0,
               cfRange.location <= existing.utf16.count {
                let start = existing.utf16.index(
                    existing.utf16.startIndex,
                    offsetBy: cfRange.location,
                    limitedBy: existing.utf16.endIndex
                ) ?? existing.utf16.endIndex
                let endOffset = min(cfRange.location + max(cfRange.length, 0), existing.utf16.count)
                let end = existing.utf16.index(
                    existing.utf16.startIndex,
                    offsetBy: endOffset,
                    limitedBy: existing.utf16.endIndex
                ) ?? existing.utf16.endIndex
                let startS = String.Index(start, within: existing) ?? existing.endIndex
                let endS = String.Index(end, within: existing) ?? existing.endIndex
                insertion = existing.replacingCharacters(in: startS..<endS, with: text)
            }
        }

        return AXUIElementSetAttributeValue(
            el, kAXValueAttribute as CFString, insertion as CFTypeRef
        ) == .success
    }

    /// Inject unicode key events — automatic typing, no clipboard / ⌘V.
    @discardableResult
    private static func typeTextDirectly(_ text: String) -> Bool {
        // Requires the process to be allowed to post HID events (Accessibility)
        guard AXIsProcessTrusted() else { return false }

        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0

        for scalar in text.unicodeScalars {
            let s = String(scalar)
            var chars = Array(s.utf16)
            guard !chars.isEmpty else { continue }

            // Special keys
            if scalar == "\n" || scalar == "\r" {
                postKey(UInt16(kVK_Return), source: src)
                continue
            }
            if scalar == "\t" {
                postKey(UInt16(kVK_Tab), source: src)
                continue
            }

            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Tiny pacing so fast apps don't drop characters
            usleep(4_000)
        }
        return true
    }

    private static func postKey(_ virtualKey: UInt16, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
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
        usleep(8_000)
        up.post(tap: .cghidEventTap)
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
          end tell
        end tell
        return "fail"
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err == nil && result?.stringValue == "ok"
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

    static func openAccessibilitySettings() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func promptAccessibilityOnce() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // Prompt so Whisper appears in the list; required for auto-paste
        _ = AXIsProcessTrustedWithOptions([key: !AXIsProcessTrusted()] as CFDictionary)
    }
}

extension Notification.Name {
    static let whisperNeedsAccessibilityForPaste = Notification.Name("whisperNeedsAccessibilityForPaste")
}
