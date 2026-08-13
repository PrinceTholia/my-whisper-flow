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
/// Do NOT gate on `hasActiveTextTarget()` — Electron/Cursor/Chrome often fail that
/// check even with a real caret, which forced “copy only” and manual ⌘V forever.
/// Do NOT call `activateIgnoringOtherApps` on normal apps — it steals caret focus.
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
        if target == nil || target?.bundleIdentifier == Bundle.main.bundleIdentifier {
            print("📋 No target app — copied only")
            return .copiedOnly
        }

        let processName = target?.localizedName
        let terminal = isTerminalApp(target)
        let alreadyFront = target == NSWorkspace.shared.frontmostApplication

        // Terminals often need a hard activate; normal apps keep caret if left alone.
        if terminal {
            target?.activate(options: [.activateIgnoringOtherApps])
        } else if !alreadyFront {
            // Soft bring-forward without killing the text field focus if possible
            target?.activate(options: [])
        }

        // Fn release / hands-free stop needs a beat before synthetic ⌘V is accepted
        let delay: TimeInterval = terminal ? 0.35 : 0.28
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            deliver(text: text, processName: processName, terminal: terminal)
        }
        return .inserted
    }

    private static func deliver(text: String, processName: String?, terminal: Bool) {
        // 1) Accessibility caret insert
        if insertViaAccessibility(text) {
            print("✅ Paste via Accessibility insert")
            return
        }

        // 2) Synthetic ⌘V (works when Accessibility grants HID posting)
        simulateCommandV()
        usleep(40_000)
        simulateCommandV()

        // 3) System Events → named process (Automation permission)
        if let processName {
            if pasteViaNSAppleScript(processName: processName) {
                print("✅ Paste via NSAppleScript (\(processName))")
                return
            }
            if pasteViaSystemEventsOsascript(processName: processName) {
                print("✅ Paste via osascript (\(processName))")
                return
            }
            if pasteViaMenu(processName: processName) {
                print("✅ Paste via Edit menu")
                return
            }
        }

        // 4) Generic System Events ⌘V
        _ = pasteViaNSAppleScript(processName: nil)
        _ = pasteViaSystemEventsOsascript(processName: nil)
        print("✅ Paste fallbacks fired (clipboard ready if HID blocked)")
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
        // Only ⌘ — clear any leftover Fn/globe from the hotkey
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
    }

    @discardableResult
    private static func pasteViaNSAppleScript(processName: String?) -> Bool {
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
            print("⚠️ NSAppleScript: \(err)")
            return false
        }
        return true
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
