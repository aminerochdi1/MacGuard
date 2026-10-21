import Foundation
import AppKit

// MARK: - Dialogs

enum Dialogs {
    static func confirm(title: String, message: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Quit / force-quit a process

enum ProcessActions {
    /// Core processes that must never be killed from here.
    static let protectedNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "MacGuard"]

    static func confirmAndTerminate(pid: Int32, name: String, force: Bool, state: AppState) {
        if pid <= 1 || pid == getpid() || protectedNames.contains(name) {
            state.notice = "“\(name)” is a core system process and can’t be quit from MacGuard."
            return
        }
        let title = force ? "Force quit “\(name)”?" : "Quit “\(name)”?"
        let msg = force
            ? "The process (PID \(pid)) is stopped immediately. Unsaved work in it will be lost."
            : "MacGuard asks the process (PID \(pid)) to quit. If it doesn’t respond, use Force Quit. Unsaved work may be lost."
        guard Dialogs.confirm(title: title, message: msg, button: force ? "Force Quit" : "Quit") else { return }

        if kill(pid, force ? SIGKILL : SIGTERM) == 0 {
            state.notice = force ? "Force quit “\(name)” (PID \(pid))." : "Asked “\(name)” (PID \(pid)) to quit. If it is still listed, use Force Quit."
        } else {
            let err = errno
            switch err {
            case EPERM:
                state.notice = "Not permitted: “\(name)” belongs to the system or another user. MacGuard doesn’t request admin rights."
            case ESRCH:
                state.notice = "“\(name)” had already exited."
            default:
                state.notice = "Couldn’t quit “\(name)” (error \(err))."
            }
        }
    }
}

// MARK: - Empty caches / Trash

enum Cleaner {
    /// Deletes the contents of ~/Library/Caches (not the folder itself). Items in use are skipped.
    static func emptyCaches() -> (freed: Int64, failed: Int) {
        let dir = NSHomeDirectory() + "/Library/Caches"
        let fm = FileManager.default
        let before = Storage.dirSize(URL(fileURLWithPath: dir))
        var failed = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            do { try fm.removeItem(atPath: dir + "/" + name) } catch { failed += 1 }
        }
        let after = Storage.dirSize(URL(fileURLWithPath: dir))
        return (max(0, before - after), failed)
    }

    /// Uses Finder so no Full Disk Access is needed. macOS asks once for permission to control Finder.
    static func emptyTrash() -> (ok: Bool, message: String) {
        guard let r = runToolFull("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty the trash"], timeout: 180) else {
            return (false, "Couldn’t start the Trash helper.")
        }
        if r.status == 0 { return (true, "Trash emptied.") }
        let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, "Finder didn’t empty the Trash. If macOS asked, allow MacGuard to control Finder in System Settings > Privacy & Security > Automation. \(detail)")
    }
}

// MARK: - Log file

enum LogWriter {
    /// Appends a timestamped block to <dir>/MacGuard-storage.log. Returns the file path or an error text.
    static func append(title: String, lines: [String], dir: String) -> (path: String?, error: String?) {
        let folder = (dir as NSString).expandingTildeInPath
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        catch { return (nil, "can’t create \(folder)") }

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        iso.formatOptions = [.withInternetDateTime]
        var text = "[\(iso.string(from: Date()))] \(title)\n"
        for l in lines { text += "  " + l + "\n" }
        text += "\n"

        let path = folder + "/MacGuard-storage.log"
        guard let data = text.data(using: .utf8) else { return (nil, "encoding error") }
        if !fm.fileExists(atPath: path) {
            return fm.createFile(atPath: path, contents: data) ? (path, nil) : (nil, "can’t write \(path)")
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return (nil, "can’t open \(path)") }
        defer { try? h.close() }
        do {
            try h.seekToEnd()
            try h.write(contentsOf: data)
            return (path, nil)
        } catch {
            return (nil, "can’t write \(path)")
        }
    }
}

// MARK: - Trust (allowlist)

enum TrustActions {
    static func confirmAndTrust(path: String, name: String, settings: Settings, state: AppState, monitor: Monitor) {
        guard !path.isEmpty else { state.notice = "“\(name)” has no known path, so it can’t be trusted."; return }
        let msg = "MacGuard will stop flagging this program:\n\(path)\n\nIt is still flagged if its name or command line matches a known crypto miner. You can remove it later in Settings > Trusted apps."
        guard Dialogs.confirm(title: "Trust “\(name)”?", message: msg, button: "Trust") else { return }
        settings.trust(path)
        state.suspects.removeAll { $0.path == path }
        state.notice = "Trusted “\(name)”. Manage trusted apps in Settings."
        if state.startupScanned { monitor.scanStartup() }
    }
}
