import AppKit
import SwiftUI
import Combine
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let controller = DictationController()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var cancellables = Set<AnyCancellable>()

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

        // Stop macOS Dictation from stealing double-Fn (live text + music pause)
        SystemConflictGuard.disableSystemFnDictationIfNeeded()

        // Prompt Accessibility at most once ever — never spam when ad-hoc trust lies
        Paster.promptAccessibilityOnce()

        NotificationCenter.default.publisher(for: .dictionaryAutoLearned)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let summary = note.userInfo?["summary"] as? String else { return }
                self?.controller.status = "📚 Learned: \(summary)"
            }
            .store(in: &cancellables)
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

        let dictionary = NSMenuItem(title: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "d")
        dictionary.target = self
        dictionary.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: nil)
        menu.addItem(dictionary)

        let ax = NSMenuItem(title: "Fix Accessibility…", action: #selector(fixAccessibility), keyEquivalent: "")
        ax.target = self
        ax.image = NSImage(systemSymbolName: "accessibility", accessibilityDescription: nil)
        menu.addItem(ax)

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

    @objc private func fixAccessibility() {
        Paster.openAccessibilitySettings()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

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
        case .copied: return "doc.on.clipboard"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "mic"
        }
    }

    private func setupPanel() {
        let hosting = NSHostingView(rootView: FloatingStatusView(controller: controller))
        let rect = NSRect(x: 0, y: 0, width: 260, height: 72)
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
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2,
                                         y: f.minY + 72))
        }
        // Resize panel to fit current hosting view
        panel.setContentSize(NSSize(width: 260, height: 72))
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !self.controller.isRecording,
               self.controller.stage == .idle {
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: - Global hotkey

    private func setupHotkey() {
        let mgr = HotkeyManager.shared

        mgr.onKeyDown = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Hybrid hold / hands-free both use start; toggle() for pure toggle mode
                if HotkeyManager.shared.currentConfig.isHoldMode {
                    if HotkeyManager.shared.handsFreeActive {
                        // Already recording in hands-free from first tap of double-tap
                        if !self.controller.isRecording {
                            self.controller.start()
                        }
                    } else {
                        self.controller.start()
                    }
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

        mgr.onHandsFreeChanged = { [weak self] active in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if active {
                    self.controller.status = "Hands-free — tap Fn to stop"
                }
            }
        }

        mgr.start()
    }
}

private func open(_ urlString: String) {
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}
