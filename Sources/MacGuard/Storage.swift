import Foundation

struct StorageInfo {
    var total: Int64
    var available: Int64      // includes purgeable space, same as Finder
}

struct CleanupItem: Identifiable {
    let id: String            // path
    let title: String
    let bytes: Int64
}

enum Storage {
    static func read() -> StorageInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return StorageInfo(total: Int64(total), available: avail)
    }

    static func dirSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Read-only scan: reports sizes, never deletes anything.
    static func scanCleanup() -> [CleanupItem] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var items: [CleanupItem] = []

        let folders: [(String, String)] = [
            ("Caches", home + "/Library/Caches"),
            ("Logs", home + "/Library/Logs"),
            ("Trash", home + "/.Trash"),
            ("Xcode DerivedData", home + "/Library/Developer/Xcode/DerivedData")
        ]
        for (title, path) in folders where fm.fileExists(atPath: path) {
            items.append(CleanupItem(id: path, title: title, bytes: dirSize(URL(fileURLWithPath: path))))
        }

        // Biggest individual cache folders
        let cachesPath = home + "/Library/Caches"
        if let kids = try? fm.contentsOfDirectory(atPath: cachesPath) {
            var sizes: [CleanupItem] = []
            for k in kids {
                let p = cachesPath + "/" + k
                sizes.append(CleanupItem(id: p, title: "Cache: " + k, bytes: dirSize(URL(fileURLWithPath: p))))
            }
            items.append(contentsOf: sizes.sorted { $0.bytes > $1.bytes }.prefix(8))
        }
        return items
    }
}
