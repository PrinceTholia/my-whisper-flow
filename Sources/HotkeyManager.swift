import Foundation
import AppKit
import Carbon.HIToolbox

/// Known modifier key codes (for modifier-only hotkeys like Fn alone)
private let kVK_Function: UInt32 = 63
private let modifierKeyCodes: Set<UInt32> = [
    63, 55, 54, 56, 60, 58, 61, 59, 62, 57,
]

/// Hotkey configuration: keyCode + modifiers + mode (toggle or hold)
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var isHoldMode: Bool
    var isModifierOnly: Bool

    var displayString: String {
        if isModifierOnly {
            let flags = NSEvent.modifierFlags(rawValue: modifiers)
            if flags.contains(.function) { return "Fn" }
            if flags.contains(.control) { return "⌃" }
            if flags.contains(.option) { return "⌥" }
            if flags.contains(.shift) { return "⇧" }
            if flags.contains(.command) { return "⌘" }
            return "modifier"
        }

        var parts: [String] = []
        if modifiers & UInt(NSEvent.modifierFlags.control.rawValue) != 0 { parts.append("⌃") }
        if modifiers & UInt(NSEvent.modifierFlags.option.rawValue) != 0 { parts.append("⌥") }
        if modifiers & UInt(NSEvent.modifierFlags.shift.rawValue) != 0 { parts.append("⇧") }
        if modifiers & UInt(NSEvent.modifierFlags.command.rawValue) != 0 { parts.append("⌘") }

        let keyNames: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "Return",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Delete): "Delete",
            UInt32(kVK_ForwardDelete): "Fwd Delete",
        ]
        let keyStr = keyNames[keyCode] ?? "Key\(keyCode)"
        return parts.joined() + keyStr
    }

    static let `default` = HotkeyConfig(
        keyCode: kVK_Function,
        modifiers: UInt(NSEvent.modifierFlags.function.rawValue),
        isHoldMode: true,
        isModifierOnly: true
    )
}

/// Global hotkey manager.
/// For Fn (modifier-only + hold):
///   • Hold Fn  → push-to-talk (release to stop)
///   • Double-tap Fn → hands-free until Fn tapped again
class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var config: HotkeyConfig
    private var isHolding = false
    private var modifierKeyDown = false
    private var lastModifierPress: TimeInterval = 0
    private let doubleTapInterval: TimeInterval = 0.4

    /// Hands-free (double-tap) session — ignore key-up until next tap.
    private(set) var handsFreeActive = false
    private var pendingHoldStop: DispatchWorkItem?

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var isActive: (() -> Bool)?
    /// Fired when hands-free starts/stops (for UI hint).
    var onHandsFreeChanged: ((Bool) -> Void)?

    private let defaultsKey = "hotkey.config"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = .default
        }
    }

    var currentConfig: HotkeyConfig { config }

    func updateConfig(_ newConfig: HotkeyConfig) {
        config = newConfig
        if let data = try? JSONEncoder().encode(newConfig) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        handsFreeActive = false
        pendingHoldStop?.cancel()
        restartMonitors()
    }

    func start() { restartMonitors() }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func restartMonitors() {
        stop()
        let eventTypes: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventTypes) { [weak self] event in
            self?.handleEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventTypes) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
    }

    private func handleEvent(_ event: NSEvent) {
        if config.isModifierOnly {
            handleModifierEvent(event)
        } else {
            handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return }
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let configFlags = NSEvent.modifierFlags(rawValue: config.modifiers)
            .intersection(.deviceIndependentFlagsMask)
        guard UInt32(event.keyCode) == config.keyCode, eventFlags == configFlags else { return }

        if event.type == .keyDown {
            if config.isHoldMode {
                guard !isHolding else { return }
                isHolding = true
                onKeyDown?()
            } else {
                onKeyDown?()
            }
        } else if event.type == .keyUp {
            if config.isHoldMode && isHolding {
                isHolding = false
                onKeyUp?()
            }
        }
    }

    /// Fn hybrid: hold = PTT, double-tap = hands-free toggle.
    private func handleModifierEvent(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let configFlags = NSEvent.modifierFlags(rawValue: config.modifiers)
        let isDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(configFlags)

        if isDown && !modifierKeyDown {
            modifierKeyDown = true
            handleModifierPressed()
        } else if !isDown && modifierKeyDown {
            modifierKeyDown = false
            handleModifierReleased()
        }
    }

    private func handleModifierPressed() {
        // Hands-free active → single tap stops
        if handsFreeActive {
            handsFreeActive = false
            pendingHoldStop?.cancel()
            lastModifierPress = 0
            onHandsFreeChanged?(false)
            onKeyUp?()
            return
        }

        // Pure toggle mode (settings): keep old double-tap-to-start / tap-to-stop
        if !config.isHoldMode {
            if isActive?() == true {
                lastModifierPress = 0
                onKeyDown?()
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastModifierPress < doubleTapInterval {
                    lastModifierPress = 0
                    onKeyDown?()
                } else {
                    lastModifierPress = now
                }
            }
            return
        }

        // Hold mode + hybrid double-tap
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastModifierPress < doubleTapInterval {
            // Second tap → cancel pending hold-stop, enter hands-free
            pendingHoldStop?.cancel()
            pendingHoldStop = nil
            lastModifierPress = 0
            handsFreeActive = true
            onHandsFreeChanged?(true)
            // Recording should already be running from first tap; if not, start
            if isActive?() != true {
                onKeyDown?()
            }
            return
        }

        lastModifierPress = now
        // First tap / hold start
        pendingHoldStop?.cancel()
        pendingHoldStop = nil
        if isActive?() != true {
            onKeyDown?()
        }
    }

    private func handleModifierReleased() {
        guard config.isHoldMode else { return }
        guard !handsFreeActive else { return } // ignore release during hands-free

        // Delay stop so a quick second tap can cancel and go hands-free
        pendingHoldStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.handsFreeActive else { return }
            self.onKeyUp?()
        }
        pendingHoldStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: work)
    }
}
