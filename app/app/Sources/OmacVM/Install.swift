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
        memory.isInstalled(thisCopy, allowSkipped: !Product.isUbuntu) || (!Product.isUbuntu && ProcessInfo.processInfo.environment["OMACVM_RESOURCES"] != nil)
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
        Product.isUbuntu ? URL(fileURLWithPath: "/Applications") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    /// Keep the installed copy in the launcher, rather than the build/download copy.
    static func registerInstalledCopy(_ app: URL, previous: URL?) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard Product.isUbuntu, FileManager.default.isExecutableFile(atPath: tool) else { return }
        let obsolete = [thisCopy.path] + (previous.map { [$0.path] } ?? [])
        for arguments in obsolete.map({ ["-u", $0] }) + [["-f", app.path]] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
        }
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
        let application = NSWorkspace.shared.runningApplications.contains {
            guard let exe = $0.executableURL, !$0.isTerminated else { return false }
            return InstallMemory.path(exe).hasPrefix(root)
        }
        return application || Storage.processLines().contains { $0.contains(root) }
    }

    /// Copies this app to FOLDER/NAME.app with NAME as its name and returns the
    /// new app. Under another name it is signed again (ad hoc); under its own
    /// it keeps its signature (a release's Developer ID).
    static func install(name: String, into folder: URL) throws -> URL {
        guard validName(name) else { throw HelperError.io("Choose a valid app name.") }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(name).app")
        guard !isSelf(name: name, in: folder) else {
            throw HelperError.io("this app is already there under that name")
        }
        if fm.fileExists(atPath: target.path) {
            if Product.isUbuntu {
                guard InstallMemory.bundleID(of: target) == Bundle.main.bundleIdentifier else {
                    throw HelperError.io("A different app already exists at \(target.path). Choose another location.")
                }
                guard InstallMemory.isNewer(thisCopy, than: target) else {
                    throw HelperError.io("\(InstallMemory.displayVersion(of: target)) is already installed. Open it instead.")
                }
            }
            guard !inUse(target) else {
                throw HelperError.io("\(name) in \(folder.path) is running. Quit it (and its VM) first")
            }
        }
        // Prepare the complete signed copy before moving the installed app.
        let staged = folder.appendingPathComponent(".\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: staged)
        if name != Product.name { try rename(staged, to: name) }
        let backup = folder.appendingPathComponent(".\(UUID().uuidString).app")
        let replacing = fm.fileExists(atPath: target.path)
        if replacing { try fm.moveItem(at: target, to: backup) }
        do { try fm.moveItem(at: staged, to: target) }
        catch {
            if replacing { try? fm.moveItem(at: backup, to: target) }
            throw error
        }
        if replacing { try? fm.trashItem(at: backup, resultingItemURL: nil) }
        markInstalled(target)
        return target
    }

    private static func rename(_ target: URL, to name: String) throws {
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
    }
}

struct InstallView: View {
    var onDone: () -> Void
    private let memory: InstallMemory
    @State private var choice: Int
    @State private var custom: String
    @State private var folder: URL
    @State private var error: String?
    @State private var removePrevious = true

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
            WindowHeader(title: "\(updating ? "Update" : "Install") \(Product.name)", facts: Product.isUbuntu ? "\(Product.buildLabel). Your Ubuntu VMs and files stay where they are." : "Its name shows in the Dock and the menu bar while \(Product.guestName) runs.") {
                AppIconButton()
            } trailing: {
                if !Product.isUbuntu {
                    Button("Run Without Installing") {
                        memory.skip(Installer.thisCopy)
                        onDone()
                    }
                }
                if Product.isUbuntu, let previous = memory.previousInstall(excluding: Installer.thisCopy) {
                    Button("Open Installed App") { open(previous) }
                }
                Button(Product.isUbuntu ? (updating ? "Update and Open" : "Install and Open") : "Install") { install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Installer.validName(name) || (Product.isUbuntu && !canInstall))
                    .layoutProbe("start")
            }
        } notices: {
            if let error { MessageStrip(text: error, error: true) }
        } content: {
            if Product.isUbuntu, let previous = memory.previousInstall(excluding: Installer.thisCopy) {
                SectionTitle(text: "Installed app", first: true)
                Card {
                    SettingRow(title: InstallMemory.displayVersion(of: previous), subtitle: previous.path, probe: "install-existing") {
                        Text(InstallMemory.isNewer(Installer.thisCopy, than: previous) ? "Update available"
                             : (InstallMemory.isNewer(previous, than: Installer.thisCopy) ? "Installed build is newer" : "Already up to date"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            SectionTitle(text: "Install", first: !Product.isUbuntu || memory.previousInstall(excluding: Installer.thisCopy) == nil)
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
                SettingRow(title: "Install location", subtitle: replaced ?? (Product.isUbuntu ? "\(folder.path)/\(name).app" : nil), probe: "install-folder") {
                    Text(StorageModel.short(folder)).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                        .help(folder.path)
                    Button("Change…") { pick() }
                }
                if Product.isUbuntu {
                    SettingRow(title: "Applications folder", subtitle: "/Applications is shared; ~/Applications belongs only to your account.", probe: "install-scope") {
                        Button("All users") { folder = URL(fileURLWithPath: "/Applications") }
                        Button("Only me") { folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications") }
                    }
                    if let previous = previousElsewhere {
                        SettingRow(title: "Previous copy", subtitle: previous.path, probe: "install-previous") {
                            Toggle("Move previous app to Trash", isOn: $removePrevious).toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    private var updating: Bool { Product.isUbuntu && memory.previousInstall(excluding: Installer.thisCopy) != nil }

    private var canInstall: Bool {
        guard !Installer.isSelf(name: name, in: folder) else { return false }
        if let previous = memory.previousInstall(excluding: Installer.thisCopy),
           !InstallMemory.isNewer(Installer.thisCopy, than: previous) { return false }
        return true
    }

    private func open(_ app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--installed-by", String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error { self.error = "Could not open \(app.path): \(error.localizedDescription)" }
                else {
                    Installer.registerInstalledCopy(app, previous: nil)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Says so when Install replaces a copy that is there already.
    private var replaced: String? {
        guard Installer.validName(name), !Installer.isSelf(name: name, in: folder) else { return nil }
        let target = folder.appendingPathComponent("\(name).app")
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let version = Product.isUbuntu ? " " + InstallMemory.displayVersion(of: target) : (InstallMemory.version(of: target).map { " \($0)" } ?? "")
        return "Replaces \(name)\(version) in this folder. Your VMs and settings stay."
    }

    private var previousElsewhere: URL? {
        guard let previous = memory.previousInstall(excluding: folder.appendingPathComponent("\(name).app")),
              InstallMemory.path(previous) != InstallMemory.path(Installer.thisCopy) else { return nil }
        return previous
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
        if Product.isUbuntu && !canInstall { return }
        if Installer.isSelf(name: name, in: folder) {
            Installer.markInstalled(Bundle.main.bundleURL)
            onDone()
            return
        }
        do {
            let previous = Product.isUbuntu && removePrevious ? previousElsewhere : nil
            if let previous, Installer.inUse(previous) { throw HelperError.io("Quit the previous app and its VMs before moving the installation.") }
            let app = try Installer.install(name: name, into: folder)
            if let previous {
                do { try FileManager.default.trashItem(at: previous, resultingItemURL: nil) }
                catch { self.error = "Installed to \(app.path), but could not move the previous copy to Trash: \(error.localizedDescription)"; return }
            }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--installed-by", String(ProcessInfo.processInfo.processIdentifier)]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.error = "Installed to \(app.path), but it did not open: \(error.localizedDescription)"
                    } else {
                        DispatchQueue.global(qos: .utility).async {
                            Installer.registerInstalledCopy(app, previous: previous)
                            DispatchQueue.main.async { NSApp.terminate(nil) }
                        }
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
