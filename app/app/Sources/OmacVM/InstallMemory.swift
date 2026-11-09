import Foundation

/// What the install dialog remembers and finds. Foundation only, so
/// src/tests/install-defaults.sh can test it on its own with a defaults suite
/// of its own (never the app's).
struct InstallMemory {
    /// The app's defaults (all copies share them: same bundle id).
    var defaults: UserDefaults
    /// Copies under another name keep this bundle id.
    var bundleID: String
    /// ~/Applications and /Applications: an app there counts as installed.
    var appFolders: [URL]

    /// The copy the dialog installed last.
    static let installedKey = "installedPath"
    /// Copies the user ran without installing (paths, newest last).
    static let skippedKey = "skipInstallPaths"
    /// Up to 2.9.0 "Run Without Installing" was one switch for every copy,
    /// later downloads too. No longer read; removed at the next choice.
    static let oldSkipKey = "skipInstall"
    static let maxSkipped = 20

    /// One spelling per place, so stored and current paths compare.
    static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// No question for this copy: it is in an Applications folder, it is the
    /// copy installed last, or the user ran this very copy without installing.
    /// An update (the app's own or omacvm update) puts the new version at the
    /// same path, so it is not asked either.
    func isInstalled(_ app: URL, allowSkipped: Bool = true) -> Bool {
        let parent = Self.path(app.deletingLastPathComponent())
        if appFolders.contains(where: { Self.path($0) == parent }) { return true }
        if let last = defaults.string(forKey: Self.installedKey),
           Self.path(URL(fileURLWithPath: last)) == Self.path(app) { return true }
        return allowSkipped && skipped(app)
    }

    func skipped(_ app: URL) -> Bool {
        (defaults.stringArray(forKey: Self.skippedKey) ?? []).contains(Self.path(app))
    }

    /// "Run Without Installing": for this copy only. A later download is a
    /// new copy and is asked again.
    func skip(_ app: URL) {
        let p = Self.path(app)
        var list = (defaults.stringArray(forKey: Self.skippedKey) ?? []).filter { $0 != p }
        list.append(p)
        defaults.set(Array(list.suffix(Self.maxSkipped)), forKey: Self.skippedKey)
        defaults.removeObject(forKey: Self.oldSkipKey)
    }

    func markInstalled(_ app: URL) {
        defaults.set(Self.path(app), forKey: Self.installedKey)
        defaults.removeObject(forKey: Self.oldSkipKey)
    }

    /// The copy installed before, which a new version replaces by default:
    /// the one the dialog installed last if it is still there, else an app
    /// with this bundle id in the Applications folders. Never ME.
    func previousInstall(excluding me: URL) -> URL? {
        let mine = Self.path(me)
        var candidates: [URL] = []
        if let last = defaults.string(forKey: Self.installedKey) {
            candidates.append(URL(fileURLWithPath: last))
        }
        for folder in appFolders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            candidates += items.filter { $0.pathExtension == "app" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return candidates.first { Self.path($0) != mine && Self.bundleID(of: $0) == bundleID }
    }

    /// What the dialog shows first: the name and folder of the copy installed
    /// before, else NAME in FOLDER (the first install's defaults).
    func preselection(for me: URL, name: String, folder: URL) -> (name: String, folder: URL) {
        guard let previous = previousInstall(excluding: me) else { return (name, folder) }
        return (previous.deletingPathExtension().lastPathComponent, previous.deletingLastPathComponent())
    }

    static func bundleID(of app: URL) -> String? { info(of: app)?["CFBundleIdentifier"] as? String }
    static func version(of app: URL) -> String? { info(of: app)?["CFBundleShortVersionString"] as? String }

    private static func info(of app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
