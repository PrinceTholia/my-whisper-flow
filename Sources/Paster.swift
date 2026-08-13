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

    static func restore(then work: @escaping () -> Void) {
        if let app, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }
}

/// Clipboard + multi-strategy paste. Never blocks on AXIsProcessTrusted() checks —
/// those return false for many ad-hoc builds even when the user enabled Accessibility.
enum Paster {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        FocusMemory.restore {
            // Strategy order: AX insert → ⌘V CGEvent → System Events AppleScript
            if insertViaAccessibility(text) { return }
            simulateCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                pasteViaSystemEvents()
            }
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

    /// Often works when AXIsProcessTrusted() lies — needs Automation → System Events.
    private static func pasteViaSystemEvents() {
        let script = """
        tell application "System Events"
          keystroke "v" using command down
        end tell
        """
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

    /// Register with TCC so Whisper appears in the Accessibility list (no dialog).
    static func promptAccessibilityOnce() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
    }
}
