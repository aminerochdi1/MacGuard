import Foundation
import AppKit

// MARK: - Pause / resume a process (SIGSTOP / SIGCONT, fully reversible)

extension ProcessActions {
    /// Freezes a process without losing its work, or lets it continue. A paused app looks frozen until resumed.
    static func togglePause(pid: Int32, name: String, state: AppState) {
        if pid <= 1 || pid == getpid() || protectedNames.contains(name) {
            state.notice = "“\(name)” is a core system process and can’t be paused from MacGuard."
            return
        }
        let resuming = state.paused.contains(pid)
        if kill(pid, resuming ? SIGCONT : SIGSTOP) == 0 {
            if resuming { state.paused.remove(pid) } else { state.paused.insert(pid) }
            state.notice = resuming
                ? "Resumed “\(name)” (PID \(pid))."
                : "Paused “\(name)” (PID \(pid)). It looks frozen until you press Resume. MacGuard resumes it automatically when MacGuard quits."
        } else {
            let err = errno
            if err == ESRCH {
                state.paused.remove(pid)
                state.notice = "“\(name)” had already exited."
            } else if err == EPERM {
                state.notice = "Not permitted: “\(name)” belongs to the system or another user. MacGuard doesn’t request admin rights."
            } else {
                state.notice = "Couldn’t \(resuming ? "resume" : "pause") “\(name)” (error \(err))."
            }
        }
    }

    /// Called when MacGuard quits so nothing stays frozen.
    static func resumeAll(_ state: AppState) {
        for pid in state.paused { _ = kill(pid, SIGCONT) }
        state.paused.removeAll()
    }
}

// MARK: - Disable / re-enable startup items and browser extensions (moves files, never deletes)

struct DisabledItem: Codable, Identifiable {
    var id: String { stored }
    let original: String
    let stored: String
    let label: String
    let scope: String
    let kind: String          // "launch" or "extension"
    let date: Date
}

enum StartupDisabler {
    static let folder = NSHomeDirectory() + "/Library/Application Support/MacGuard/Disabled"
    private static let key = "disabledItems"

    static func load() -> [DisabledItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([DisabledItem].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [DisabledItem]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// What can be moved aside for this item, or nil if MacGuard can only show it in Finder.
    static func target(for item: StartupItem) -> (kind: String, path: String)? {
        let fm = FileManager.default
        switch item.category {
        case .launch:
            guard let p = item.revealPath, p.hasSuffix(".plist"),
                  p.hasPrefix(NSHomeDirectory() + "/Library/LaunchAgents/"),
                  fm.isWritableFile(atPath: (p as NSString).deletingLastPathComponent) else { return nil }
            return ("launch", p)
        case .browser:
            guard !item.id.contains("#"), item.id.hasSuffix("/manifest.json") else { return nil }
            let idDir = URL(fileURLWithPath: item.id).deletingLastPathComponent().deletingLastPathComponent()
            guard idDir.deletingLastPathComponent().lastPathComponent == "Extensions",
                  fm.isWritableFile(atPath: idDir.path) else { return nil }
            return ("extension", idDir.path)
        default:
            return nil
        }
    }

    static func canDisable(_ item: StartupItem) -> Bool { target(for: item) != nil }

    static func disable(_ item: StartupItem, state: AppState, monitor: Monitor) {
        guard let t = target(for: item) else {
            state.notice = "MacGuard can only disable items in your own LaunchAgents folder and Chromium extensions. Use Show in Finder for this one."
            return
        }
        let msg: String
        if t.kind == "launch" {
            msg = "MacGuard stops this login item and moves its file to:\n\(folder)\n\nNothing is deleted. Re-enable it later from the “Disabled by MacGuard” list."
        } else {
            msg = "MacGuard moves this extension out of your browser’s profile to:\n\(folder)\n\nQuit the browser first, otherwise it may keep using the extension until it restarts. Nothing is deleted. Re-enable it later from the “Disabled by MacGuard” list."
        }
        guard Dialogs.confirm(title: "Disable “\(item.label)”?", message: msg, button: "Disable") else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let stored = folder + "/" + String(UUID().uuidString.prefix(8)) + "-" + (t.path as NSString).lastPathComponent
            if t.kind == "launch" {
                _ = runToolFull("/bin/launchctl", ["bootout", "gui/\(getuid())", t.path], timeout: 10)
            }
            try fm.moveItem(atPath: t.path, toPath: stored)
            var list = load()
            list.append(DisabledItem(original: t.path, stored: stored, label: item.label, scope: item.scope, kind: t.kind, date: Date()))
            save(list)
            state.disabledItems = list
            state.notice = "Disabled “\(item.label)”. Re-enable it any time from Startup > Disabled by MacGuard."
            monitor.scanStartup()
        } catch {
            state.notice = "Couldn’t disable “\(item.label)”: \(error.localizedDescription)"
        }
    }

    static func enable(_ d: DisabledItem, state: AppState, monitor: Monitor) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: d.stored) else {
            state.notice = "The saved file for “\(d.label)” is gone. Removing it from the list."
            remove(d, state: state)
            return
        }
        guard !fm.fileExists(atPath: d.original) else {
            state.notice = "Something already exists at the original location of “\(d.label)”, so it wasn’t moved back."
            return
        }
        do {
            try fm.moveItem(atPath: d.stored, toPath: d.original)
            if d.kind == "launch" {
                _ = runToolFull("/bin/launchctl", ["bootstrap", "gui/\(getuid())", d.original], timeout: 10)
                state.notice = "Re-enabled “\(d.label)”."
            } else {
                state.notice = "Re-enabled “\(d.label)”. Restart the browser to load it again."
            }
            remove(d, state: state)
            monitor.scanStartup()
        } catch {
            state.notice = "Couldn’t re-enable “\(d.label)”: \(error.localizedDescription)"
        }
    }

    private static func remove(_ d: DisabledItem, state: AppState) {
        let list = load().filter { $0.stored != d.stored }
        save(list)
        state.disabledItems = list
    }
}
