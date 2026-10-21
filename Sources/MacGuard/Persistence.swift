import Foundation

// Extra places where software can keep itself running: shell startup files, cron, browser extensions,
// and library injection into apps. Everything here is read-only and written from Apple's and the
// browsers' documented file locations. The ideas for which places to check come from studying
// Objective-See's KnockKnock; no code from it is used.

enum StartupCategory { case launch, shell, browser }

enum PersistenceScanner {

    static func scanAll(sig: SignatureChecker) -> [StartupItem] {
        shellAndCron() + browserExtensions() + appInjection(sig: sig)
    }

    // MARK: Shared helpers

    private static func short(_ s: String, _ n: Int = 110) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    /// Scores one command line or text for the things startup malware tends to do.
    static func assess(_ text: String) -> (score: Int, why: [String], miner: Bool) {
        var score = 0
        var why: [String] = []
        var miner = false
        if let t = Heuristics.minerTerm(in: text) {
            score += 5; miner = true; why.append("Matches known miner indicator: \(t)")
        }
        let l = text.lowercased()
        let downloads = l.contains("curl ") || l.contains("wget ")
        let pipesToShell = l.contains("| sh") || l.contains("|sh") || l.contains("| bash") || l.contains("|bash") || l.contains("| zsh")
        if downloads && pipesToShell { score += 3; why.append("Downloads code and runs it") }
        else if downloads { score += 1; why.append("Downloads from the internet") }
        if l.contains("base64") { score += 2; why.append("Decodes base64 data") }
        if l.contains("/dev/tcp/") { score += 4; why.append("Opens a network socket from the shell") }
        if Heuristics.tempPrefixes.contains(where: { text.contains($0) }) { score += 3; why.append("Uses a temporary/shared folder") }
        return (score, why, miner)
    }

    private static func make(id: String, label: String, scope: String, program: String, args: [String],
                             category: StartupCategory, sig: SigStatus = .notApplicable, modified: Date? = nil,
                             score: Int, why: [String], miner: Bool) -> StartupItem {
        var score = score
        var why = why
        let trusted = Allowlist.contains(program) && !miner
        if trusted { score = 0; why = ["Trusted by you (allowlist)"] }
        return StartupItem(id: id, label: label, scope: scope, program: program, arguments: args,
                           runAtLoad: true, keepAlive: false, signature: sig, modified: modified,
                           score: score, reasons: why, trusted: trusted, category: category)
    }

    private static func readText(_ path: String, limit: Int = 2_000_000) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: limit) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func modDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Shell startup files and cron

    static func shellAndCron() -> [StartupItem] {
        let home = NSHomeDirectory()
        let userFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".bash_profile", ".bashrc", ".profile"]
            .map { home + "/" + $0 }
        let systemFiles = ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin", "/etc/zlogout", "/etc/bashrc", "/etc/profile"]
        var items: [StartupItem] = []

        for path in userFiles + systemFiles {
            guard let text = readText(path) else { continue }
            let isSystem = path.hasPrefix("/etc/")
            let lines = text.split(whereSeparator: { $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if lines.isEmpty { continue }

            var best = 0
            var miner = false
            var why: [String] = []
            for line in lines {
                let a = assess(line)
                if a.score > 0 {
                    best = max(best, a.score)
                    miner = miner || a.miner
                    if why.count < 6 { why.append("\(a.why.first ?? "Unusual"): \(short(line, 90))") }
                }
            }
            // The default system files are always present, so list them only when something looks wrong
            if isSystem && best == 0 { continue }
            if why.isEmpty { why = ["\(lines.count) command lines, nothing unusual"] }
            items.append(make(id: path, label: (path as NSString).lastPathComponent,
                              scope: isSystem ? "Shell file (system-wide)" : "Shell file (yours)",
                              program: path, args: [], category: .shell, modified: modDate(path),
                              score: best, why: why, miner: miner))
        }

        if let out = runTool("/usr/bin/crontab", ["-l"], timeout: 4) {
            for raw in out.split(whereSeparator: { $0.isNewline }) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let a = assess(line)
                items.append(make(id: "crontab:" + line, label: short(line, 70), scope: "Cron job", program: "crontab:" + line,
                                  args: [line], category: .shell, score: a.score,
                                  why: a.why.isEmpty ? ["Scheduled by your crontab"] : a.why, miner: a.miner))
            }
        }
        return items
    }

    // MARK: Browser extensions (Chromium-based browsers and Firefox; Safari extensions are not covered)

    static func browserExtensions() -> [StartupItem] {
        var items: [StartupItem] = []
        let fm = FileManager.default
        let support = NSHomeDirectory() + "/Library/Application Support/"
        let chromium: [(String, String)] = [
            ("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"),
            ("Vivaldi", "Vivaldi"), ("Opera", "com.operasoftware.Opera"), ("Arc", "Arc/User Data")
        ]

        for (browser, sub) in chromium {
            let base = support + sub
            guard let top = try? fm.contentsOfDirectory(atPath: base) else { continue }
            var profiles = top.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.map { base + "/" + $0 }
            if profiles.isEmpty, fm.fileExists(atPath: base + "/Extensions") { profiles = [base] }

            for profile in profiles {
                let extDir = profile + "/Extensions"
                guard let ids = try? fm.contentsOfDirectory(atPath: extDir) else { continue }
                for id in ids where id != "Temp" && !id.hasPrefix(".") {
                    guard let versions = try? fm.contentsOfDirectory(atPath: extDir + "/" + id),
                          let latest = versions.filter({ !$0.hasPrefix(".") }).sorted().last else { continue }
                    let root = extDir + "/" + id + "/" + latest
                    let manifestPath = root + "/manifest.json"
                    guard let data = fm.contents(atPath: manifestPath),
                          let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

                    let name = resolveName(manifest, root: root) ?? id
                    var perms = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
                    perms += (manifest["host_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
                    let text = String(decoding: data, as: UTF8.self)
                    items.append(extensionItem(name: name, browser: browser, program: manifestPath, perms: perms,
                                               text: name + " " + text, modified: modDate(manifestPath)))
                }
            }
        }

        // Firefox: extensions.json in each profile
        let ffBase = support + "Firefox/Profiles"
        if let profiles = try? fm.contentsOfDirectory(atPath: ffBase) {
            for p in profiles where !p.hasPrefix(".") {
                let file = ffBase + "/" + p + "/extensions.json"
                guard let data = fm.contents(atPath: file),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let addons = obj["addons"] as? [[String: Any]] else { continue }
                for a in addons where (a["type"] as? String) == "extension" && (a["location"] as? String) == "app-profile" {
                    let id = (a["id"] as? String) ?? "unknown"
                    let name = ((a["defaultLocale"] as? [String: Any])?["name"] as? String) ?? id
                    let up = a["userPermissions"] as? [String: Any]
                    let perms = ((up?["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }
                        + ((up?["origins"] as? [Any]) ?? []).compactMap { $0 as? String }
                    items.append(extensionItem(name: name, browser: "Firefox", program: file + "#" + id, perms: perms,
                                               text: name + " " + id, modified: modDate(file)))
                }
            }
        }
        return items
    }

    private static func resolveName(_ manifest: [String: Any], root: String) -> String? {
        guard let raw = manifest["name"] as? String else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        let locale = (manifest["default_locale"] as? String) ?? "en"
        for loc in [locale, "en"] {
            guard let data = FileManager.default.contents(atPath: root + "/_locales/" + loc + "/messages.json"),
                  let msgs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for (k, v) in msgs where k.lowercased() == key {
                if let m = (v as? [String: Any])?["message"] as? String { return m }
            }
        }
        return nil
    }

    private static func extensionItem(name: String, browser: String, program: String, perms: [String],
                                      text: String, modified: Date?) -> StartupItem {
        var score = 0
        var why: [String] = []
        var miner = false
        if let t = Heuristics.minerTerm(in: text) {
            score += 5; miner = true; why.append("Matches known miner indicator: \(t)")
        }
        let broad = perms.contains { $0 == "<all_urls>" || $0 == "*://*/*" || $0 == "http://*/*" || $0 == "https://*/*" }
        if broad { why.append("Can read and change data on all websites") }
        if perms.contains("nativeMessaging") { score += 1; why.append("Can talk to apps on your Mac") }
        if perms.contains("debugger") { score += 1; why.append("Can debug other pages") }
        if why.isEmpty { why = ["Limited permissions"] }
        return make(id: program, label: name, scope: "\(browser) extension", program: program, args: perms,
                    category: .browser, modified: modified, score: score, why: why, miner: miner)
    }

    // MARK: Library injection into apps (LSEnvironment in Info.plist)

    static func appInjection(sig: SignatureChecker) -> [StartupItem] {
        let fm = FileManager.default
        var items: [StartupItem] = []
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let apps = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for app in apps where app.hasSuffix(".app") {
                let bundle = dir + "/" + app
                guard let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") as? [String: Any],
                      let env = info["LSEnvironment"] as? [String: Any] else { continue }
                let value = (env["DYLD_INSERT_LIBRARIES"] as? String) ?? (env["__XPC_DYLD_INSERT_LIBRARIES"] as? String)
                guard let libs = value, !libs.isEmpty else { continue }

                var score = 4
                var why = ["Injects a library into this app (DYLD_INSERT_LIBRARIES): \(short(libs, 90))"]
                for lib in libs.split(separator: ":").map(String.init) where lib.hasPrefix("/") {
                    let s = sig.check(lib)
                    if s == .unsigned { score += 2; why.append("Injected library is not code-signed"); break }
                    if s == .missing { score += 1; why.append("Injected library not found"); break }
                }
                let exe = (info["CFBundleExecutable"] as? String) ?? (app as NSString).deletingPathExtension
                let program = bundle + "/Contents/MacOS/" + exe
                items.append(make(id: bundle + "#inject", label: (app as NSString).deletingPathExtension,
                                  scope: "App library injection", program: program, args: [libs], category: .launch,
                                  sig: sig.check(program), modified: modDate(bundle + "/Contents/Info.plist"),
                                  score: score, why: why, miner: false))
            }
        }
        return items
    }
}

// MARK: - "New since last scan": remembers when each item was first seen

enum StartupBaseline {
    private static let key = "startupFirstSeen"
    static let freshDays = 7.0

    /// Marks items first seen within the last 7 days and returns those seen for the first time in THIS scan.
    /// The very first scan only records a baseline, so nothing is reported as new then.
    static func apply(_ items: [StartupItem]) -> (items: [StartupItem], fresh: [StartupItem]) {
        let d = UserDefaults.standard
        let previous = d.dictionary(forKey: key) as? [String: Double]
        let hasBaseline = previous != nil
        let known = previous ?? [:]
        let now = Date().timeIntervalSince1970

        var out = items
        var next: [String: Double] = [:]
        var fresh: [StartupItem] = []
        for i in out.indices {
            let id = out[i].id
            let first: Double
            if let t = known[id] { first = t } else { first = hasBaseline ? now : 0 }
            next[id] = first
            if known[id] == nil && hasBaseline { fresh.append(out[i]) }
            if first > 0, now - first < freshDays * 86400 {
                out[i].isNew = true
                out[i].firstSeen = Date(timeIntervalSince1970: first)
            }
        }
        d.set(next, forKey: key)
        return (out, fresh)
    }
}

/// One full scan: launch items + shell/cron + browser extensions + library injection, with the "new" marks applied.
enum StartupFullScan {
    static func run(sig: SignatureChecker) -> (items: [StartupItem], fresh: [StartupItem]) {
        var all = StartupScanner.scan(sig: sig) + PersistenceScanner.scanAll(sig: sig)
        all.sort { $0.score != $1.score ? $0.score > $1.score : $0.label < $1.label }
        return StartupBaseline.apply(all)
    }
}
