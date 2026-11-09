import AppKit
import SwiftUI

/// First start from a download or build folder: the app installs itself under
/// the name the user picks (OmacVM, Omarchy or their own) and opens from there.
enum Installer {
    static var memory: InstallMemory {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return InstallMemory(defaults: .standard, bundleID: Bundle.main.bundleIdentifier ?? "org.omacvm.app",
                             appFolders: [home, URL(fileURLWithPath: "/Applications")])
    }

    static var isInstalled: Bool {
        memory.isInstalled(thisCopy) || ProcessInfo.processInfo.environment["OMACVM_RESOURCES"] != nil
    }

    /// Where this copy is, as the user sees it. A download that macOS runs
    /// from a temporary place (App Translocation, new path each time) gives
    /// its real place, so "Run Without Installing" sticks to it.
    static let thisCopy: URL = originalURL(of: Bundle.main.bundleURL) ?? Bundle.main.bundleURL

    /// Security.framework's SecTranslocateCreateOriginalPathForURL (public
    /// symbol, no header): nil when the app is not translocated.
    private static func originalURL(of url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(sym, to: Fn.self)(url as CFURL, nil)
        return original?.takeRetainedValue() as URL?
    }

    /// The user's own Applications folder (~/Applications): no admin rights
    /// needed, and the omacvm command looks there first.
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    static func validName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        // No "," either: QEMU shows the name, and its options split at commas.
        return !n.isEmpty && n.count <= 40 && !n.contains("/") && !n.contains(":") && !n.contains(",") && !n.hasPrefix(".")
    }

    /// FOLDER/NAME.app is this very app: nothing to copy.
    static func isSelf(name: String, in folder: URL) -> Bool {
        let target = InstallMemory.path(folder.appendingPathComponent("\(name).app"))
        return target == InstallMemory.path(thisCopy) || target == InstallMemory.path(Bundle.main.bundleURL)
    }

    /// Remembers the copy in a folder of the user's choice as installed (the
    /// copies share their settings: same bundle id).
    static func markInstalled(_ app: URL) {
        memory.markInstalled(app)
    }

    /// An app runs from APP (a VM's window is QEMU inside the bundle): it
    /// must not be replaced under it.
    static func inUse(_ app: URL) -> Bool {
        let root = InstallMemory.path(app) + "/"
        return NSWorkspace.shared.runningApplications.contains {
            guard let exe = $0.executableURL, !$0.isTerminated else { return false }
            return InstallMemory.path(exe).hasPrefix(root)
        }
    }

    /// Copies this app to FOLDER/NAME.app with NAME as its name and returns the
    /// new app. Under another name it is signed again (ad hoc); under its own
    /// it keeps its signature (a release's Developer ID).
    static func install(name: String, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(name).app")
        guard !isSelf(name: name, in: folder) else {
            throw HelperError.io("this app is already there under that name")
        }
        if fm.fileExists(atPath: target.path) {
            guard !inUse(target) else {
                throw HelperError.io("\(name) in \(folder.path) is running. Quit it (and its VM) first")
            }
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: Bundle.main.bundleURL, to: target)
        if name == Product.name {
            markInstalled(target)
            return target
        }
        let plist = target.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        guard var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperError.io("Info.plist is unreadable")
        }
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        let out = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try out.write(to: plist)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        let id = Bundle.main.bundleIdentifier ?? "org.omacvm.app"
        sign.arguments = ["--force", "--sign", "-", "--identifier", id,
                          "-r=designated => identifier \"\(id)\"", target.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw HelperError.io("could not sign \(target.path)") }
        markInstalled(target)
        return target
    }
}

struct InstallView: View {
    var onDone: () -> Void
    private let memory: InstallMemory
    @State private var choice: Int
    @State private var custom: String
    @State private var folder: URL
    @State private var error: String?

    /// Starts on the name and folder of the copy installed before, so a new
    /// version replaces it in place; the first install on OmacVM in the
    /// default folder.
    init(memory: InstallMemory = Installer.memory, firstFolder: URL = Installer.defaultFolder,
         onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.memory = memory
        let pick = memory.preselection(for: Installer.thisCopy, name: Product.name, folder: firstFolder)
        let preset = [Product.isUbuntu ? "UbuntuVM" : "OmacVM", Product.guestName].firstIndex(of: pick.name)
        _choice = State(initialValue: preset ?? 2)
        _custom = State(initialValue: preset == nil ? pick.name : "")
        _folder = State(initialValue: pick.folder)
    }

    private var name: String {
        switch choice {
        case 0: Product.isUbuntu ? "UbuntuVM" : "OmacVM"
        case 1: Product.guestName
        default: custom.trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        WindowShell {
            WindowHeader(title: "Install \(Product.name)", facts: "Its name shows in the Dock and the menu bar while \(Product.guestName) runs.") {
                AppIconButton()
            } trailing: {
                Button("Run Without Installing") {
                    memory.skip(Installer.thisCopy)
                    onDone()
                }
                Button("Install") { install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Installer.validName(name))
                    .layoutProbe("start")
            }
        } notices: {
            if let error { MessageStrip(text: error, error: true) }
        } content: {
            SectionTitle(text: "Install", first: true)
            Card {
                SettingRow(title: "Name", probe: "install-name") {
                    if choice == 2 {
                        TextField("Name", text: $custom).labelsHidden().frame(width: 180)
                    }
                    Picker("Name", selection: $choice) {
                        Text(Product.isUbuntu ? "UbuntuVM" : "OmacVM").tag(0)
                        Text(Product.guestName).tag(1)
                        Text("Your Own").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow(title: "Folder", subtitle: replaced, probe: "install-folder") {
                    Text(StorageModel.short(folder)).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                        .help(folder.path)
                    Button("Change…") { pick() }
                }
            }
        }
    }

    /// Says so when Install replaces a copy that is there already.
    private var replaced: String? {
        guard Installer.validName(name), !Installer.isSelf(name: name, in: folder) else { return nil }
        let target = folder.appendingPathComponent("\(name).app")
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let version = InstallMemory.version(of: target).map { " \($0)" } ?? ""
        return "Replaces \(name)\(version) in this folder. Your VMs and settings stay."
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func install() {
        if Installer.isSelf(name: name, in: folder) {
            Installer.markInstalled(Bundle.main.bundleURL)
            onDone()
            return
        }
        do {
            let app = try Installer.install(name: name, into: folder)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--installed-by", String(ProcessInfo.processInfo.processIdentifier)]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.error = "Installed to \(app.path), but it did not open: \(error.localizedDescription)"
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            self.error = "Could not install: \(error.localizedDescription)"
        }
    }
}

/// Where VM disks may go: APFS or Mac OS Extended (sparse files), 30 GB free.
enum VolumeCheck {
    static func problem(with folder: URL) -> String? {
        if let drive = Storage.missingDrive(for: folder) { return "\(drive) is not connected." }
        if folder.path.contains("\n") { return "That folder's name has a line break; pick another." }
        var st = statfs()
        let existing = sequence(first: folder) { $0.deletingLastPathComponent() }
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? folder
        guard statfs(existing.path, &st) == 0 else { return "That folder cannot be read." }
        let type = withUnsafeBytes(of: st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard type == "apfs" || type == "hfs" else {
            return "That drive is \(type.uppercased()). The VM's disk needs APFS or Mac OS Extended."
        }
        let free = Double(st.f_bavail) * Double(st.f_bsize) / 1e9
        if free < 30 { return "That drive has \(Int(free)) GB free; the VM needs at least 30 GB." }
        return nil
    }
}
