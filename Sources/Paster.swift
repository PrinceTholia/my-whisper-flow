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
    case inserted
    case copiedOnly
}

/// Clipboard + auto-paste into the app that was focused when recording started.
///
/// Ad-hoc builds often make `AXIsProcessTrusted()` lie. Never treat that as
/// “no caret / no permission” and skip paste. Prefer System Events ⌘V (Automation)
/// over synthetic typing, which can “succeed” while events are silently dropped.
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

        let target = FocusMemory.current ?? NSWorkspace.shared.frontmostApplication
        if target?.bundleIdentifier == Bundle.main.bundleIdentifier || target == nil {
            print("📋 No target app — copied only")
            return .copiedOnly
        }

        // Only skip when AX truly works and confirms there is no text caret
        if AXIsProcessTrusted(), !hasActiveTextTarget() {
            print("📋 No active cursor — copied only")
            return .copiedOnly
        }

        let processName = target?.localizedName
        let terminal = isTerminalApp(target)

        // Bring the original app forward so paste lands in the caret the user had
        target?.activate(options: [.activateIgnoringOtherApps])

        let delay: TimeInterval = terminal ? 0.30 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 1) Real Accessibility insert (best when TCC matches this binary)
            if insertViaAccessibility(text) {
                print("✅ Paste via Accessibility insert")
                return
            }

            // 2) System Events ⌘V into the target process (needs Automation permission)
            if let processName, pasteViaSystemEventsOsascript(processName: processName) {
                print("✅ Paste via System Events (\(processName))")
                return
            }

            // 3) Edit → Paste menu (Terminals especially)
            if let processName, pasteViaMenu(processName: processName) {
                print("✅ Paste via Edit menu")
                return
            }

            // 4) Synthetic ⌘V + generic System Events
            simulateCommandV()
            _ = pasteViaSystemEventsOsascript(processName: nil)
            print("✅ Paste via synthetic ⌘V fallback")
        }
        return .inserted
    }

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

        let nonText: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
            "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
            "AXTab", "AXToolbar", "AXSlider", "AXImage", "AXStaticText", "AXLink",
        ]
        if nonText.contains(role) { return false }

        let textRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
            "AXEditableText", "AXWebArea",
        ]
        if textRoles.contains(role) { return true }
        if role.localizedCaseInsensitiveContains("text") { return true }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            el, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, rangeRef != nil {
            return true
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        return isTerminalApp(FocusMemory.current)
    }

    // MARK: - Insert strategies

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

    private static func simulateCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.localEventsSuppressionInterval = 0
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
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
          end tell
        end tell
        return "fail"
        """
        return runOsascript(script) == "ok"
    }

    /// Returns true when osascript exits 0 (best-effort — System Events may still need Automation).
    @discardableResult
    private static func pasteViaSystemEventsOsascript(processName: String?) -> Bool {
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
        return runOsascript(script) != nil
    }

    private static func runOsascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            if let e = String(data: errData, encoding: .utf8), !e.isEmpty {
                print("⚠️ osascript: \(e)")
            }
            return nil
        }
        return text ?? ""
    }

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// New binary (ad-hoc rebuild) → old Accessibility grant may not apply. Re-prompt.
    static func refreshTrustPromptIfBinaryChanged() {
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            promptAccessibilityOnce()
            return
        }
        let token = "\(modified.timeIntervalSince1970)-\(size)"
        let prev = UserDefaults.standard.string(forKey: exeTokenKey)
        if prev != token {
            UserDefaults.standard.set(token, forKey: exeTokenKey)
            UserDefaults.standard.set(false, forKey: didPromptKey)
            print("🔁 New Whisper binary — will re-prompt Accessibility")
        }
        promptAccessibilityOnce()
    }

    static func promptAccessibilityOnce() {
        if UserDefaults.standard.bool(forKey: didPromptKey) { return }
        UserDefaults.standard.set(true, forKey: didPromptKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Warm Automation permission (System Events) without pasting user data.
    static func warmAutomationPermission() {
        DispatchQueue.global().async {
            _ = runOsascript("""
            tell application "System Events"
              return name of first process whose frontmost is true
            end tell
            """)
        }
    }
}

extension Notification.Name {
    static let whisperNeedsAccessibilityForPaste = Notification.Name("whisperNeedsAccessibilityForPaste")
}
