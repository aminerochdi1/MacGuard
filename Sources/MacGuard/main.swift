import AppKit
import SwiftUI
import Combine

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    let settings = Settings()
    var monitor: Monitor!
    var notch: NotchController!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = Monitor(state: state)
        monitor.updateConfig(settings.config)
        settings.onChange = { [weak self] in
            guard let self = self else { return }
            self.monitor.updateConfig(self.settings.config)
            self.applyTheme()
            self.notch.setEnabled(self.settings.notchPopover)
        }
        notch = NotchController(state: state)
        notch.setEnabled(settings.notchPopover)
        applyTheme()

        Notifier.shared.setup()
        if settings.alerts { Notifier.shared.requestAuthorization() }

        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MacGuard"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(s: state, settings: settings, monitor: monitor))
        window.center()
        window.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show MacGuard", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.title = "MacGuard"

        state.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.statusItem.button?.title = text }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: window, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.monitor.setVisible(self.window.occlusionState.contains(.visible))
        }

        monitor.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyTheme() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !settings.keepInBackground
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MacGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
