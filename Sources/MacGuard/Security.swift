import Foundation
import Security

// MARK: - Heuristics (indicators, never verdicts)

enum Heuristics {
    static let minerTerms = [
        "xmrig", "xmr-stak", "minerd", "cpuminer", "ethminer", "nbminer", "lolminer", "phoenixminer",
        "cgminer", "bfgminer", "nicehash", "minergate", "stratum+tcp", "stratum+ssl", "stratum+tls",
        "--donate-level", "supportxmr", "moneroocean", "nanopool", "c3pool", "hashvault", "2miners",
        "f2pool", "unmineable"
    ]

    /// Ports commonly used by mining pools. Alone this is weak evidence (4444/5555 have other uses).
    static let poolPorts: Set<Int> = [3333, 3334, 4444, 5555, 6666, 7777, 9999, 14433, 14444, 45560, 45700]

    static let tempPrefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/",
                               "/Users/Shared/", "/private/var/folders/", "/var/folders/"]

    static let systemNames: Set<String> = ["mdworker", "mdworker_shared", "mshelper", "kernel_task", "launchd",
                                           "windowserver", "coreaudiod", "syslogd", "softwareupdated"]
    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    static let interpreters: Set<String> = ["bash", "sh", "zsh", "python", "python3", "perl", "ruby",
                                            "osascript", "node", "curl", "wget"]

    static func minerTerm(in text: String) -> String? {
        let t = text.lowercased()
        return minerTerms.first { t.contains($0) }
    }

    static func pathRisk(_ path: String) -> (points: Int, reason: String)? {
        if path.isEmpty { return nil }
        if tempPrefixes.contains(where: { path.hasPrefix($0) }) {
            return (3, "Runs from a temporary/shared folder")
        }
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0.count > 1 }) {
            return (2, "Runs from a hidden folder")
        }
        return nil
    }

    static func masquerades(name: String, path: String) -> Bool {
        guard !path.isEmpty, systemNames.contains(name.lowercased()) else { return false }
        return !systemPrefixes.contains(where: { path.hasPrefix($0) })
    }
}

// MARK: - Code signature check (in-process, no shelling out)

enum SigStatus: String {
    case apple = "Apple"
    case signed = "Signed"
    case unsigned = "Unsigned"
    case invalid = "Invalid"
    case missing = "Missing"
}

final class SignatureChecker {
    private var cache: [String: SigStatus] = [:]
    private let lock = NSLock()

    func check(_ path: String) -> SigStatus {
        lock.lock()
        if let c = cache[path] { lock.unlock(); return c }
        lock.unlock()

        let result = compute(path)
        lock.lock(); cache[path] = result; lock.unlock()
        return result
    }

    private func compute(_ path: String) -> SigStatus {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code = code else { return .unsigned }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSBasicValidateOnly))
        let st = SecStaticCodeCheckValidity(code, flags, nil)
        if st == -67062 { return .unsigned }          // errSecCSUnsigned
        if st != errSecSuccess { return .invalid }
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req = req,
           SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess {
            return .apple
        }
        return .signed
    }
}

// MARK: - Risk level

enum Risk: String {
    case high = "High", medium = "Mid", low = "Low"
    static func from(_ score: Int) -> Risk { score >= 6 ? .high : (score >= 3 ? .medium : .low) }
}

// MARK: - Startup items (LaunchAgents / LaunchDaemons)

struct StartupItem: Identifiable {
    let id: String               // plist path
    let label: String
    let scope: String
    let program: String
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let signature: SigStatus
    let modified: Date?
    var score: Int
    var reasons: [String]
    var risk: Risk { Risk.from(score) }
}

enum StartupScanner {
    static func scan(sig: SignatureChecker) -> [StartupItem] {
        let home = NSHomeDirectory()
        let dirs: [(String, String)] = [
            (home + "/Library/LaunchAgents", "User agent"),
            ("/Library/LaunchAgents", "System-wide agent"),
            ("/Library/LaunchDaemons", "System daemon")
        ]
        var items: [StartupItem] = []
        let fm = FileManager.default

        for (dir, scope) in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                guard let data = fm.contents(atPath: path),
                      let obj = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
                else { continue }

                let label = (obj["Label"] as? String) ?? f
                let args = (obj["ProgramArguments"] as? [String]) ?? []
                let program = (obj["Program"] as? String) ?? args.first ?? ""
                let runAtLoad = (obj["RunAtLoad"] as? Bool) ?? false
                var keepAlive = false
                if let b = obj["KeepAlive"] as? Bool { keepAlive = b } else if obj["KeepAlive"] != nil { keepAlive = true }
                let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date

                var score = 0
                var why: [String] = []
                let status: SigStatus = program.isEmpty ? .missing : sig.check(program)

                switch status {
                case .missing: score += 1; why.append("Executable not found (orphaned entry)")
                case .unsigned: score += 2; why.append("Executable is not code-signed")
                case .invalid: score += 3; why.append("Code signature is invalid (modified after signing?)")
                default: break
                }
                if let t = Heuristics.minerTerm(in: label + " " + args.joined(separator: " ")) {
                    score += 5; why.append("Matches known miner indicator: \(t)")
                }
                if let r = Heuristics.pathRisk(program) { score += r.points; why.append(r.reason) }
                if label.hasPrefix("com.apple.") && status != .apple {
                    score += 3; why.append("Pretends to be an Apple item but is not Apple-signed")
                }

                let base = (program as NSString).lastPathComponent
                if Heuristics.interpreters.contains(base) {
                    let joined = args.joined(separator: " ")
                    if let script = args.dropFirst().first(where: { !$0.hasPrefix("-") && fm.fileExists(atPath: $0) }) {
                        why.append("Runs script: \(script)")
                        if let r = Heuristics.pathRisk(script) { score += r.points; why.append("Script: " + r.reason.lowercased()) }
                    } else if args.contains("-c") {
                        score += 1; why.append("Runs an inline shell command")
                    }
                    if joined.contains("curl ") || joined.contains("wget ") || joined.contains("base64") || joined.contains("| sh") || joined.contains("|sh") {
                        score += 2; why.append("Downloads or decodes code at startup")
                    }
                }
                if let m = modified, Date().timeIntervalSince(m) < 7 * 86400 {
                    score += 1; why.append("Added or changed in the last 7 days")
                }

                items.append(StartupItem(id: path, label: label, scope: scope, program: program, arguments: args,
                                         runAtLoad: runAtLoad, keepAlive: keepAlive, signature: status,
                                         modified: modified, score: score, reasons: why))
            }
        }
        return items.sorted { $0.score != $1.score ? $0.score > $1.score : $0.label < $1.label }
    }
}

// MARK: - Network (pool-port connections) via lsof, own processes only

struct NetFinding: Identifiable {
    let id = UUID()
    let pid: Int32
    let process: String
    let remote: String
}

enum NetScanner {
    /// Returns established TCP connections whose remote port is a common mining-pool port.
    static func scan() -> [NetFinding] {
        guard let text = runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pcn"], timeout: 10) else { return [] }
        var pid: Int32 = 0
        var cmd = ""
        var out: [NetFinding] = []
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let rest = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(rest) ?? 0
            case "c": cmd = rest
            case "n":
                guard let r = rest.range(of: "->") else { continue }
                let remote = String(rest[r.upperBound...])
                if let colon = remote.lastIndex(of: ":"), let port = Int(remote[remote.index(after: colon)...]),
                   Heuristics.poolPorts.contains(port) {
                    out.append(NetFinding(pid: pid, process: cmd, remote: remote))
                }
            default: break
            }
        }
        return out
    }
}

// MARK: - Live process suspicion scoring

struct Suspect: Identifiable {
    let id: Int32
    let name: String
    let path: String
    let cpu: Double
    let score: Int
    let reasons: [String]
    var risk: Risk { Risk.from(score) }
}

final class Detector {
    let sig = SignatureChecker()
    private var argsCache: [Int32: [String]] = [:]
    var netPids: Set<Int32> = []

    private func args(_ pid: Int32) -> [String] {
        if let c = argsCache[pid] { return c }
        let a = ProcessSampler.arguments(pid)
        argsCache[pid] = a
        return a
    }

    /// `deep` reads command lines of every readable process; otherwise only busy or path-flagged ones.
    func evaluate(procs: [ProcInfo], sustained: (Int32) -> Double?, gui: Set<Int32>, deep: Bool) -> [Suspect] {
        let me = getpid()
        var alive = Set<Int32>()
        var out: [Suspect] = []

        for p in procs where p.id != me && p.id > 1 {
            alive.insert(p.id)
            var score = 0
            var why: [String] = []
            var strong = false   // any signal other than "odd folder" / "unsigned"

            if let t = Heuristics.minerTerm(in: p.name + " " + p.path) {
                strong = true
                score += 5; why.append("Name or path matches known miner: \(t)")
            }
            let pr = Heuristics.pathRisk(p.path)
            if let pr = pr { score += pr.points; why.append(pr.reason) }
            if Heuristics.masquerades(name: p.name, path: p.path) {
                strong = true
                score += 3; why.append("Uses a system process name but is not in a system folder")
            }
            if p.readable, deep || p.cpu >= 15 || pr != nil {
                let a = args(p.id).joined(separator: " ")
                if let t = Heuristics.minerTerm(in: a) { strong = true; score += 5; why.append("Command line contains: \(t)") }
            }
            if let avg = sustained(p.id), avg >= 80 {
                strong = true
                score += 2; why.append(String(format: "Sustained %.0f%% of one core for ~30 s", avg))
                if !gui.contains(p.id) { score += 1; why.append("Not a foreground app") }
            }
            if netPids.contains(p.id) { strong = true; score += 2; why.append("Connected to a common mining-pool port") }

            if score > 0, !p.path.isEmpty {
                let s = sig.check(p.path)
                if s == .unsigned { score += 2; why.append("Binary is not code-signed") }
                if s == .invalid { score += 2; why.append("Binary signature is invalid") }
                if s == .apple, score < 5 { continue }   // genuine Apple binary with only weak signals
                // Validly signed app (Chrome, VS Code...) whose only signal is its folder: macOS keeps
                // updated and translocated apps under /private/var/folders, so this is normal.
                if s == .signed, !strong { continue }
            }
            if score >= 3 {
                out.append(Suspect(id: p.id, name: p.name, path: p.path, cpu: p.cpu, score: score, reasons: why))
            }
        }
        argsCache = argsCache.filter { alive.contains($0.key) }
        return out.sorted { $0.score > $1.score }
    }
}
