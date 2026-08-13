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

enum PasteOutcome: Equatable {
    /// Text was inserted at the active caret.
    case inserted
    /// No active text cursor — left on clipboard for manual ⌘V.
    case copiedOnly
}

/// Smart auto-paste: insert only when a text caret is active; otherwise copy + notify.
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

    /// Deliver text. Returns whether it was auto-inserted or clipboard-only.
    @discardableResult
    static func paste(_ text: String) -> PasteOutcome {
        guard !text.isEmpty else { return .copiedOnly }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Without Accessibility we cannot find the caret or insert — copy only
        guard AXIsProcessTrusted() else {
            print("📋 Accessibility off — copied only")
            return .copiedOnly
        }

        // No active text caret → copy only (do not dump text into random UI)
        guard hasActiveTextTarget() else {
            print("📋 No active cursor — copied only")
            return .copiedOnly
        }

        let target = FocusMemory.current
        let terminal = isTerminalApp(target)
        if terminal {
            target?.activate(options: [.activateIgnoringOtherApps])
        }

        let delay: TimeInterval = terminal ? 0.28 : 0.08
        // Fire async insert; outcome for UI is "inserted" because a caret was present
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if insertViaAccessibility(text) {
                print("✅ Inserted via Accessibility")
                return
            }
            if typeTextDirectly(text) {
                print("✅ Inserted via direct typing")
                return
            }
            if terminal, let name = target?.localizedName, pasteViaMenu(processName: name) {
                print("✅ Inserted via Terminal menu")
                return
            }
            // Last automatic attempt
            simulateCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                pasteViaSystemEvents(processName: terminal ? target?.localizedName : nil)
            }
        }
        return .inserted
    }

    /// True when focus is in something that can accept typed/pasted text.
    static func hasActiveTextTarget() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return false }

        let el = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        // Never treat chrome controls as a caret target
        let nonText: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
            "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
            "AXTab", "AXToolbar", "AXSlider", "AXIncrementor",
            "AXImage", "AXStaticText", "AXLink",
        ]
        if nonText.contains(role) { return false }

        let textRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
            "AXEditableText", "AXWebArea",
        ]
        if textRoles.contains(role) { return true }
        if role.localizedCaseInsensitiveContains("text") { return true }

        // Caret / selection range present → editable
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            el, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, rangeRef != nil {
            return true
        }

        // Electron / web: settable selected text or value
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue,
           role != "AXScrollArea" {
            return true
        }

        // Terminal: frontmost + any focus counts as ready for paste
        if isTerminalApp(FocusMemory.current) {
            return true
        }

        return false
    }

    // MARK: - Insert strategies

    @discardableResult
    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
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

    @discardableResult
    private static func typeTextDirectly(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0

        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                postKey(UInt16(kVK_Return), source: src); continue
            }
            if scalar == "\t" {
                postKey(UInt16(kVK_Tab), source: src); continue
            }
            var chars = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3_000)
        }
        return true
    }

    private static func postKey(_ virtualKey: UInt16, source: CGEventSource?) {
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    private static func simulateCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
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
        _ = AXIsProcessTrustedWithOptions([key: !AXIsProcessTrusted()] as CFDictionary)
    }
}
