import SwiftUI
import AppKit

// About window: who made MacGuard, plus a manual "Check for updates" that compares this version
// with the latest GitHub release. The only network request is the one you trigger with the button.

enum AppInfo {
    static let repo = "aminerochdi1/MacGuard"
    static let author = "Rochdi Mohammed Amine"
    static var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev" }
    static var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0" }
    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var issuesURL: URL { URL(string: "https://github.com/\(repo)/issues/new")! }
    static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases")! }
}

// MARK: - Update check

final class UpdateChecker: ObservableObject {
    enum State {
        case idle, checking, noReleases
        case upToDate(String)
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published var state: State = .idle

    /// true when `remote` is a higher version than `local` (leading "v" ignored, missing parts count as 0).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let clean = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return clean.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    func check() {
        if case .checking = state { return }
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacGuard/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: State
            if let err = err {
                result = .failed("Couldn’t reach GitHub (\(err.localizedDescription)). Check your connection.")
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                result = .noReleases
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 429 {
                result = .failed("GitHub is limiting requests right now. Try again in a few minutes.")
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failed("GitHub answered with status \(http.statusCode).")
            } else if let data = data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = obj["tag_name"] as? String {
                let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesURL
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                result = UpdateChecker.isNewer(tag, than: AppInfo.version) ? .available(version: latest, url: page) : .upToDate(latest)
            } else {
                result = .failed("Unexpected answer from GitHub.")
            }
            DispatchQueue.main.async { self.state = result }
        }.resume()
    }
}

// MARK: - Window

final class AboutWindow {
    static let shared = AboutWindow()
    private var window: NSWindow?
    private let checker = UpdateChecker()

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About MacGuard"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AboutView(checker: checker))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View

struct AboutView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacGuard").font(.serif(34)).tracking(-0.4).foregroundColor(Theme.ink)
                    Text("Version \(AppInfo.version) (build \(AppInfo.build))")
                        .font(.sans(14)).foregroundColor(Theme.slate)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("About me").font(.sans(17, .medium)).foregroundColor(Theme.ink)
                Text("Hi, I’m \(AppInfo.author), a developer based in France.")
                    .font(.sans(15)).foregroundColor(Theme.ink)
                Text("I made MacGuard for my own needs, to see what is heating up my Mac and whether something shady is running, and I’m sharing it with everyone who might find it useful.")
                    .font(.sans(14)).foregroundColor(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ideas and bug reports are welcome on GitHub.")
                    .font(.sans(14)).foregroundColor(Theme.slate)
            }
            .card(padding: 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Updates").font(.sans(17, .medium)).foregroundColor(Theme.ink)
                updateStatus
                HStack(spacing: 10) {
                    Button("Check for updates") { checker.check() }
                        .buttonStyle(PillStyle(kind: .filled)).disabled(isChecking)
                    if case .available(_, let url) = checker.state {
                        Button("Download") { NSWorkspace.shared.open(url) }.buttonStyle(PillStyle(kind: .ghost))
                    }
                }
                Text("Only contacts GitHub when you press the button.")
                    .font(.sans(13)).foregroundColor(Theme.slate)
            }
            .card(padding: 20)

            HStack(spacing: 22) {
                ArrowLink(title: "GitHub") { NSWorkspace.shared.open(AppInfo.repoURL) }
                ArrowLink(title: "Report an issue") { NSWorkspace.shared.open(AppInfo.issuesURL) }
                ArrowLink(title: "Releases") { NSWorkspace.shared.open(AppInfo.releasesURL) }
            }
            Text("Inspired by Objective-See’s KnockKnock. Not a replacement for an antivirus.")
                .font(.sans(13)).foregroundColor(Theme.slate)
        }
        .padding(28)
        .frame(width: 480, alignment: .leading)
        .background(Theme.canvas)
    }

    private var isChecking: Bool {
        if case .checking = checker.state { return true }
        return false
    }

    @ViewBuilder private var updateStatus: some View {
        switch checker.state {
        case .idle:
            Text("Compare this version with the latest release on GitHub.").font(.sans(14)).foregroundColor(Theme.slate)
        case .checking:
            Text("Checking…").font(.sans(14)).foregroundColor(Theme.slate)
        case .noReleases:
            Text("No release has been published yet, so there is nothing newer.").font(.sans(14)).foregroundColor(Theme.slate)
        case .upToDate(let v):
            Text("Up to date. You have \(AppInfo.version); the latest release is \(v).")
                .font(.sans(14, .medium)).foregroundColor(Theme.low)
        case .available(let v, _):
            Text("Update available: \(v). You have \(AppInfo.version).")
                .font(.sans(14, .medium)).foregroundColor(Theme.mid)
        case .failed(let msg):
            Text(msg).font(.sans(14)).foregroundColor(Theme.high)
        }
    }
}
