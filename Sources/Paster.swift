import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Remembers which app had focus when dictation started, so paste returns there.
enum FocusMemory {
    private static var app: NSRunningApplication?

    static func capture() {
        app = NSWorkspace.shared.frontmostApplication
    }

    static var current: NSRunningApplication? { app }

    static func restore(delay: TimeInterval = 0.20, then work: @escaping () -> Void) {
        if let app, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }
}

/// Clipboard + multi-strategy paste.
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
        "com.hrbrmstr.rio",
        "com.mitchellh.ghostty",
    ]

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Terminal prefers plain string; also set the older NeXT type some apps expect
        pb.setString(text, forType: .string)
        pb.setString(text, forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))

        let target = FocusMemory.current
        let isTerminal = isTerminalApp(target)

        // Terminals need a longer activate delay; AX insert usually fails there
        let delay: TimeInterval = isTerminal ? 0.35 : 0.20
        FocusMemory.restore(delay: delay) {
            if isTerminal {
                pasteIntoTerminal(app: target)
                return
            }
            if insertViaAccessibility(text) { return }
            simulateCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                pasteViaSystemEvents(processName: nil)
            }
        }
    }

    private static func isTerminalApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        if terminalBundleIDs.contains(id) { return true }
        // Heuristic for lesser-known terminals
        let name = (app?.localizedName ?? "").lowercased()
        return name.contains("terminal") || name.contains("iterm")
            || name.contains("kitty") || name.contains("warp")
            || name.contains("alacritty") || name.contains("ghostty")
            || name.contains("wezterm") || name.contains("hyper")
    }

    /// Terminals ignore AX text insert; target the process and use Paste menu / ⌘V.
    private static func pasteIntoTerminal(app: NSRunningApplication?) {
        let processName = app?.localizedName ?? "Terminal"
        // 1) Menu Paste (most reliable in Terminal.app / iTerm)
        if pasteViaMenu(processName: processName) { return }
        // 2) Process-scoped ⌘V
        pasteViaSystemEvents(processName: processName)
        // 3) Raw CGEvent as last resort (after a beat)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulateCommandV()
        }
    }

    @discardableResult
    private static func pasteViaMenu(processName: String) -> Bool {
        let escaped = processName.replacingOccurrences(of: "\\", with: "\\\\")
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
        if let err {
            print("⚠️ Terminal menu paste: \(err)")
            return false
        }
        return (result?.stringValue == "ok")
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

        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
           let existing = valueRef as? String {
            var rangeRef: CFTypeRef?
            var insertion = existing + text
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
            if AXUIElementSetAttributeValue(
                el, kAXValueAttribute as CFString, insertion as CFTypeRef
            ) == .success {
                return true
            }
        }
        return false
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
            let escaped = processName.replacingOccurrences(of: "\\", with: "\\\\")
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
        }
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
