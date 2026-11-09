import Foundation

// Offline tests of InstallMemory (app/app/Sources/OmacVM/InstallMemory.swift):
// which copy the install dialog preselects and when it is not shown. Fake
// Applications folders in a temporary folder; a defaults suite of its own.

var failed = 0
func expect(_ what: String, _ ok: Bool) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failed += 1 }
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let userApps = root.appendingPathComponent("home/Applications")
let sysApps = root.appendingPathComponent("Applications")
let downloads = root.appendingPathComponent("Downloads")
let custom = root.appendingPathComponent("My Apps")
for d in [userApps, sysApps, downloads, custom] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }

let id = "org.omacvm.app"
@discardableResult
func makeApp(_ folder: URL, _ name: String, id: String = id, version: String = "2.8.0") -> URL {
    let app = folder.appendingPathComponent("\(name).app")
    try? fm.removeItem(at: app)
    try! fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": version]
    try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
}

let suite = CommandLine.arguments[2]
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
let memory = InstallMemory(defaults: defaults, bundleID: id, appFolders: [userApps, sysApps])
func reset() {
    defaults.removePersistentDomain(forName: suite)
    for d in [userApps, sysApps, downloads, custom] {
        for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
    }
}

let download = makeApp(downloads, "OmacVM", version: "2.9.0")

// First install ever: the defaults (OmacVM in the default folder).
var pick = memory.preselection(for: download, name: "OmacVM", folder: userApps)
expect("first install: asked", !memory.isInstalled(download))
expect("first install: OmacVM", pick.name == "OmacVM")
expect("first install: default folder", InstallMemory.path(pick.folder) == InstallMemory.path(userApps))

// A copy installed earlier as "Omarchy" in /Applications: preselected.
makeApp(sysApps, "Omarchy")
makeApp(sysApps, "Another App", id: "com.example.other")
makeApp(userApps, "OmacVM Test Build", id: "org.omacvm.sutest")
pick = memory.preselection(for: download, name: "OmacVM", folder: userApps)
expect("earlier Omarchy in /Applications: name", pick.name == "Omarchy")
expect("earlier Omarchy in /Applications: folder", InstallMemory.path(pick.folder) == InstallMemory.path(sysApps))
expect("other bundle ids are not a previous install",
       memory.previousInstall(excluding: download)?.lastPathComponent == "Omarchy.app")

// The copy the dialog installed last wins, in any folder.
let work = makeApp(custom, "Work VM")
memory.markInstalled(work)
pick = memory.preselection(for: download, name: "OmacVM", folder: userApps)
expect("installedPath first: name", pick.name == "Work VM")
expect("installedPath first: folder", InstallMemory.path(pick.folder) == InstallMemory.path(custom))
// ... unless it is gone: back to the Applications folders.
try! fm.removeItem(at: work)
expect("installedPath gone: the one in /Applications",
       memory.previousInstall(excluding: download)?.lastPathComponent == "Omarchy.app")

// The running copy itself is never "the copy before".
reset()
let installed = makeApp(userApps, "OmacVM")
expect("no previous install but me", memory.previousInstall(excluding: installed) == nil)
expect("in ~/Applications: not asked", memory.isInstalled(installed))
expect("in /Applications: not asked", memory.isInstalled(makeApp(sysApps, "Omarchy")))

// Paths spelt another way (symlinks, ..) are the same place.
reset()
let link = root.appendingPathComponent("dl-link")
try? fm.removeItem(at: link)
try! fm.createSymbolicLink(at: link, withDestinationURL: downloads)
let dl = makeApp(downloads, "OmacVM", version: "2.9.0")
memory.markInstalled(link.appendingPathComponent("OmacVM.app"))
expect("installedPath through a symlink matches", memory.isInstalled(dl))
expect("installedPath with .. matches",
       memory.isInstalled(URL(fileURLWithPath: downloads.path + "/../Downloads/OmacVM.app")))

// Run Without Installing: this copy only, not every later download.
reset()
let a = makeApp(downloads, "OmacVM", version: "2.9.0")
let b = makeApp(downloads, "OmacVM 2", version: "2.9.1")
memory.skip(a)
expect("skipped copy: not asked again", memory.isInstalled(a))
expect("Ubuntu ignores a previous skip choice", !memory.isInstalled(a, allowSkipped: false))
expect("another download: asked", !memory.isInstalled(b))
expect("skip writes no installedPath", defaults.string(forKey: InstallMemory.installedKey) == nil)
memory.skip(a)
expect("skip twice: listed once", defaults.stringArray(forKey: InstallMemory.skippedKey)?.count == 1)
for i in 0..<30 { memory.skip(downloads.appendingPathComponent("copy \(i).app")) }
let list = defaults.stringArray(forKey: InstallMemory.skippedKey) ?? []
expect("skip list kept short", list.count == InstallMemory.maxSkipped)
expect("skip list keeps the newest", list.last == InstallMemory.path(downloads.appendingPathComponent("copy 29.app")))

// The old switch for every copy is no longer read, and goes at the next choice.
reset()
defaults.set(true, forKey: InstallMemory.oldSkipKey)
let c = makeApp(downloads, "OmacVM", version: "2.9.0")
expect("old global skip: a new download is asked", !memory.isInstalled(c))
memory.skip(c)
expect("old global skip removed by a choice", defaults.object(forKey: InstallMemory.oldSkipKey) == nil)
defaults.set(true, forKey: InstallMemory.oldSkipKey)
memory.markInstalled(c)
expect("old global skip removed by an install", defaults.object(forKey: InstallMemory.oldSkipKey) == nil)

// Updates put the new version at the same path: never asked.
reset()
let mine = makeApp(custom, "Omarchy", version: "2.9.0")
memory.markInstalled(mine)
let updated = makeApp(custom, "Omarchy", version: "3.0.0")   // the app's own update swaps the bundle in place
expect("self-update of a copy in its own folder: not asked", memory.isInstalled(updated))
let ran = makeApp(downloads, "OmacVM", version: "2.9.0")
memory.skip(ran)
expect("self-update of a copy run without installing: not asked",
       memory.isInstalled(makeApp(downloads, "OmacVM", version: "3.0.0")))
expect("omacvm update (into ~/Applications): not asked", memory.isInstalled(makeApp(userApps, "OmacVM", version: "3.0.0")))
expect("omacvm update (into /Applications): not asked", memory.isInstalled(makeApp(sysApps, "OmacVM", version: "3.0.0")))

defaults.removePersistentDomain(forName: suite)
print(failed == 0 ? "all install-defaults checks passed" : "\(failed) install-defaults check(s) failed")
exit(failed == 0 ? 0 : 1)
