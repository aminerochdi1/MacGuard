import SwiftUI
import AppKit

// MARK: - Models

struct BigFile: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date?
}

struct FolderSize: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
}

// MARK: - Scanner (read-only; cancellable)

final class LargeFileScanner {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Walks `root` once: keeps the biggest files (>= minBytes) and totals per top-level child.
    /// App bundles and other packages are not entered (counted as skipped), symlinks are ignored.
    func scan(root: URL, minBytes: Int64, progress: @escaping (Int) -> Void)
        -> (files: [BigFile], folders: [FolderSize], scanned: Int, wasCancelled: Bool) {

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else {
            return ([], [], 0, false)
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var files: [BigFile] = []
        var totals: [String: Int64] = [:]
        var count = 0

        for case let u as URL in en {
            if isCancelled { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            count += 1
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            let p = u.path

            if p.hasPrefix(rootPath) {
                let rel = p.dropFirst(rootPath.count)
                let first = rel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
                if !first.isEmpty { totals[first, default: 0] += size }
            }
            if size >= minBytes {
                files.append(BigFile(path: p, size: size, modified: v.contentModificationDate))
                if files.count > 400 {
                    files.sort { $0.size > $1.size }
                    files.removeLast(files.count - 200)
                }
            }
            if count % 2000 == 0 { progress(count) }
        }
        files.sort { $0.size > $1.size }
        let folders = totals.sorted { $0.value > $1.value }.prefix(15)
            .map { FolderSize(path: rootPath + $0.key, size: $0.value) }
        return (Array(files.prefix(200)), folders, count, isCancelled)
    }
}

// MARK: - Actions

enum LargeFileActions {
    /// Moves to the Trash (recoverable), never deletes permanently.
    static func confirmAndTrash(_ f: BigFile, state: AppState, monitor: Monitor) {
        let name = (f.path as NSString).lastPathComponent
        guard Dialogs.confirm(title: "Move “\(name)” to the Trash?",
                              message: "\(fmtBytesFile(f.size)) will be freed once the Trash is emptied. You can still put it back from the Trash until then.",
                              button: "Move to Trash") else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)
            state.bigFiles.removeAll { $0.path == f.path }
            state.notice = "Moved “\(name)” to the Trash (\(fmtBytesFile(f.size)))."
            monitor.logEvent(title: "Moved to Trash", lines: ["\(f.path) (\(fmtBytesFile(f.size)))"])
        } catch {
            state.notice = "Couldn’t move “\(name)” to the Trash: \(error.localizedDescription)"
        }
    }
}

// MARK: - View

struct LargeFilesView: View {
    @ObservedObject var s: AppState
    let monitor: Monitor
    @State private var minMB: Int64 = 50

    private var shown: [BigFile] {
        Array(s.bigFiles.filter { $0.size >= minMB * 1_000_000 }.prefix(60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            status
            folders
            files
            Text("App bundles (.app and similar packages) are not entered, so their size is not counted here. Protected folders such as Desktop or Documents make macOS ask for access the first time.")
                .font(.sans(14)).foregroundColor(Theme.slate)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Scan home folder") { monitor.scanLarge(root: NSHomeDirectory()) }
                .buttonStyle(PillStyle(kind: .filled)).disabled(s.bigScanning)
            Button("Choose folder…") { choose() }
                .buttonStyle(PillStyle(kind: .ghost)).disabled(s.bigScanning)
            if s.bigScanning {
                Button("Stop") { monitor.cancelLarge() }.buttonStyle(PillStyle(kind: .ghost))
            }
            Spacer()
            Text("Show files over").font(.sans(14)).foregroundColor(Theme.slate)
            ForEach([Int64(50), 200, 1000], id: \.self) { mb in
                Button(mb >= 1000 ? "1 GB" : "\(mb) MB") { minMB = mb }
                    .buttonStyle(PillStyle(kind: minMB == mb ? .filled : .ghost))
            }
        }
    }

    @ViewBuilder private var status: some View {
        if s.bigScanning {
            Text("Scanning \(s.bigRoot)… \(s.bigScannedCount) files so far").font(.sans(14)).foregroundColor(Theme.slate)
        } else if let d = s.bigDone {
            Text("Scanned \(s.bigScannedCount) files in \(s.bigRoot) · \(d.formatted(date: .omitted, time: .standard))")
                .font(.sans(14)).foregroundColor(Theme.slate)
        } else {
            Text("Find what is taking your disk space. Nothing is deleted without your confirmation.")
                .font(.sans(14)).foregroundColor(Theme.slate)
        }
    }

    @ViewBuilder private var folders: some View {
        if !s.bigFolders.isEmpty {
            let top = Double(s.bigFolders.first?.size ?? 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("Biggest folders in \(s.bigRoot)").font(.sans(17, .medium)).foregroundColor(Theme.ink)
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                ForEach(s.bigFolders) { f in
                    HStack(spacing: 12) {
                        Text((f.path as NSString).lastPathComponent).font(.sans(15)).foregroundColor(Theme.ink)
                            .lineLimit(1).frame(width: 220, alignment: .leading)
                        Bar(fraction: Double(f.size) / max(top, 1), tint: Theme.ink)
                        Text(fmtBytesFile(f.size)).font(.sans(14)).monospacedDigit().foregroundColor(Theme.ink)
                            .frame(width: 90, alignment: .trailing)
                        ArrowLink(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 7)
                }
                Spacer().frame(height: 10)
            }
            .artifact()
        }
    }

    @ViewBuilder private var files: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Largest files").font(.sans(17, .medium)).foregroundColor(Theme.ink)
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
                ForEach(shown) { f in
                    BigFileRow(f: f, s: s, monitor: monitor)
                    Divider()
                }
            }
            .artifact()
        } else if !s.bigScanning, s.bigDone != nil {
            Text("No files over \(minMB >= 1000 ? "1 GB" : "\(minMB) MB") found.").font(.sans(15)).foregroundColor(Theme.slate)
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Scan"
        p.message = "Choose a folder or drive to scan for large files."
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        if p.runModal() == .OK, let u = p.url { monitor.scanLarge(root: u.path) }
    }
}

struct BigFileRow: View {
    let f: BigFile
    let s: AppState
    let monitor: Monitor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(fmtBytesFile(f.size)).font(.sans(15, .medium)).monospacedDigit().foregroundColor(Theme.ink)
                .frame(width: 90, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text((f.path as NSString).lastPathComponent).font(.sans(15)).foregroundColor(Theme.ink).lineLimit(1)
                Text((f.path as NSString).deletingLastPathComponent).font(.sans(13)).foregroundColor(Theme.slate)
                    .lineLimit(1).truncationMode(.middle)
                if let m = f.modified {
                    Text("Modified " + m.formatted(date: .abbreviated, time: .omitted)).font(.sans(13)).foregroundColor(Theme.slate)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                ArrowLink(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                Button("Move to Trash") { LargeFileActions.confirmAndTrash(f, state: s, monitor: monitor) }
                    .buttonStyle(PillStyle(kind: .ghost))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
            Button("Move to Trash") { LargeFileActions.confirmAndTrash(f, state: s, monitor: monitor) }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(f.path, forType: .string)
            }
        }
    }
}
