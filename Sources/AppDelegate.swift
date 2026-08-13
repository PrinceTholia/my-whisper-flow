import AppKit
import SwiftUI
import Combine
import AVFoundation
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let controller = DictationController()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var cancellables = Set<AnyCancellable>()
    private var updaterController: SPUStandardUpdaterController!

    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var dictionaryWindow: NSWindow?

    private var toggleItem: NSMenuItem!
    private var cloudItem: NSMenuItem!
    private var correctionItem: NSMenuItem!
    private var backtrackItem: NSMenuItem!
    private var langMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        KeyStore.prewarm()
        setupStatusItem()
        setupPanel()
        setupHotkey()

        // Update icon / panel based on processing stage
        controller.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                guard let self = self else { return }
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: Self.iconName(for: stage),
                    accessibilityDescription: "Whisper"
                )
                let hk = HotkeyManager.shared.currentConfig.displayString
                if stage == .recording {
                    self.toggleItem.title = "Stop Speaking (\(hk))"
                } else if stage == .idle {
                    self.toggleItem.title = "Start Speaking (\(hk))"
                }
                if stage == .idle { self.hidePanel() } else { self.showPanel() }
            }
            .store(in: &cancellables)

        controller.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.statusItem.button?.toolTip = s }
            .store(in: &cancellables)

        // Request Accessibility permission once (required for auto ⌘V paste)
        Paster.promptAccessibilityOnce()

        NotificationCenter.default.publisher(for: .dictionaryAutoLearned)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let summary = note.userInfo?["summary"] as? String else { return }
                self?.controller.status = "📚 Learned: \(summary)"
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .whisperPasteNeedsAccessibility)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.controller.status = "⚠️ Enable Accessibility — text is on clipboard (⌘V)"
                self?.controller.stage = .error("Enable Accessibility for auto-paste")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if case .error = self?.controller.stage { self?.controller.stage = .idle }
                }
            }
            .store(in: &cancellables)

        // Sparkle auto-updater (checks SUFeedURL on launch + daily)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Whisper")

        let menu = NSMenu()
        let hk = HotkeyManager.shared.currentConfig.displayString
        toggleItem = NSMenuItem(title: "Start Speaking (\(hk))", action: #selector(toggleAction), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        cloudItem = NSMenuItem(title: "STT: Cloud", action: #selector(toggleCloud), keyEquivalent: "")
        cloudItem.target = self
        correctionItem = NSMenuItem(title: "AI Correction", action: #selector(toggleCorrection), keyEquivalent: "")
        correctionItem.target = self
        backtrackItem = NSMenuItem(title: "Backtrack", action: #selector(toggleBacktrack), keyEquivalent: "")
        backtrackItem.target = self
        menu.addItem(cloudItem)
        menu.addItem(correctionItem)
        menu.addItem(backtrackItem)
        menu.addItem(.separator())

        let langMenu = NSMenu()
        let autoItem = NSMenuItem(title: Languages.auto.name, action: #selector(setLanguage(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = Languages.auto.code
        langMenu.addItem(autoItem)
        langMenu.addItem(.separator())
        for lang in Languages.all {
            let item = NSMenuItem(title: lang.name, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            langMenu.addItem(item)
        }
        let langParent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langParent.submenu = langMenu
        menu.addItem(langParent)
        self.langMenu = langMenu
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(updates)

        let whatsNew = NSMenuItem(title: "What's New…", action: #selector(openChangelog), keyEquivalent: "")
        whatsNew.target = self
        whatsNew.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(whatsNew)

        let dictionary = NSMenuItem(title: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "d")
        dictionary.target = self
        dictionary.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: nil)
        menu.addItem(dictionary)

        let about = NSMenuItem(title: "About Whisper", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
        updateStates()
    }

    func menuWillOpen(_ menu: NSMenu) { updateStates() }

    private func updateStates() {
        // Keep Backtrack in sync if toggled from Settings
        let bt = UserDefaults.standard.bool(forKey: "backtrackEnabled")
        if controller.useBacktrack != bt { controller.useBacktrack = bt }

        cloudItem.state = controller.useCloudSTT ? .on : .off
        cloudItem.title = "STT: Cloud (\(STTSettings.current.name))"
        correctionItem.state = controller.useCorrection ? .on : .off
        correctionItem.title = "AI Correction (\(LLMSettings.current.name))"
        backtrackItem.state = controller.useBacktrack ? .on : .off
        backtrackItem.title = "Backtrack (self-corrections)"
        let hk = HotkeyManager.shared.currentConfig.displayString
        toggleItem.title = controller.isRecording ? "Stop Speaking (\(hk))" : "Start Speaking (\(hk))"
        for item in langMenu.items {
            let code = item.representedObject as? String
            item.state = (code == controller.language) ? .on : .off
        }
    }

    @objc private func toggleAction() { controller.toggle() }
    @objc private func toggleCloud() { controller.useCloudSTT.toggle(); updateStates() }
    @objc private func toggleCorrection() { controller.useCorrection.toggle(); updateStates() }
    @objc private func toggleBacktrack() {
        controller.useBacktrack.toggle()
        updateStates()
    }
    @objc private func setLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { controller.language = code }
        updateStates()
    }

    @objc private func checkForUpdates() {
        updaterController?.updater.checkForUpdates()
    }

    @objc private func openChangelog() {
        if let url = URL(string: "https://gamezxz.github.io/WhisperApp/changelog") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Whisper Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        // Menu-bar app (.accessory) can't receive keyboard focus
        // → Switch to .regular temporarily so the key fields accept input
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        if aboutWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About Whisper"
            w.contentView = NSHostingView(rootView: AboutView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            aboutWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openDictionary() {
        if dictionaryWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Custom Dictionary"
            w.contentView = NSHostingView(rootView: DictionaryView())
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            dictionaryWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dictionaryWindow?.makeKeyAndOrderFront(nil)
    }

    // Return to menu-bar mode when a window closes (hide from Dock)
    func windowWillClose(_ notification: Notification) {
        let win = notification.object as? NSWindow
        if win === settingsWindow || win === aboutWindow || win === dictionaryWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Floating status panel

    private static func iconName(for stage: Stage) -> String {
        switch stage {
        case .recording: return "mic.fill"
        case .transcribing: return "waveform.circle"
        case .correcting: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "mic"
        }
    }

    private func setupPanel() {
        let hosting = NSHostingView(rootView: FloatingStatusView(controller: controller))
        let rect = NSRect(x: 0, y: 0, width: 200, height: 72)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
    }

    private func showPanel() {
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            // Bottom-center like the preview mock (~72pt above Dock)
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                         y: f.minY + 72))
        }
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        // Slight delay so waveform fades out smoothly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !self.controller.isRecording { self.panel.orderOut(nil) }
        }
    }

    // MARK: - Global hotkey

    private func setupHotkey() {
        let mgr = HotkeyManager.shared

        // Toggle mode: press to start, press again to stop
        mgr.onKeyDown = { [weak self] in
            DispatchQueue.main.async { self?.controller.toggle() }
        }

        // Hold mode: keyDown → start, keyUp → stop (handled inside toggle via holdMode flag)
        // For hold mode, we need separate start/stop callbacks
        mgr.onKeyDown = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if HotkeyManager.shared.currentConfig.isHoldMode {
                    self.controller.start()
                } else {
                    self.controller.toggle()
                }
            }
        }

        mgr.onKeyUp = { [weak self] in
            DispatchQueue.main.async {
                self?.controller.stop()
            }
        }

        mgr.isActive = { [weak self] in
            self?.controller.isRecording ?? false
        }

        mgr.start()
    }
}
