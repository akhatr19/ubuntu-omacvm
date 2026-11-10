import AppKit
import NetFS
import SwiftUI

/// NetFS handles Finder's SMB credentials; the app never puts passwords in URLs.
enum UbuntuDriveMount {
    nonisolated static func mount(port: Int, user: String, share: String, password: String?) -> (error: String?, path: String?) {
        guard (1024...65535).contains(port), ["Root", "Home"].contains(share), let url = URL(string: "smb://127.0.0.1:\(port)/\(share)") else { return ("Invalid Finder connection.", nil) }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey]) ?? []
        for volume in volumes {
            guard let remote = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  remote.scheme == "smb", remote.host == "127.0.0.1", remote.port == port,
                  remote.lastPathComponent == share else { continue }
            return (nil, volume.path)
        }
        let options = NSMutableDictionary(dictionary: ["AllowLoopback": true, "UIOption": "AllowUI", "ForceNewSession": true])
        let mountOptions = NSMutableDictionary(dictionary: share == "Root" ? ["MountFlags": Int(MNT_RDONLY), "SoftMount": true] : ["SoftMount": true])
        var points: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(url as CFURL, nil, user as CFString, password.map { $0 as CFString }, options, mountOptions, &points)
        let paths = points?.takeRetainedValue() as? [String]
        guard status == 0 else { return (status == -128 ? "Finder connection cancelled." : "Finder could not mount the Linux share (\(status)). Check its sharing password.", nil) }
        return (nil, paths?.first)
    }

    static func eject(port: Int) async -> String? {
        guard (1024...65535).contains(port) else { return "Invalid Finder port." }
        return await Task.detached { () -> String? in
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey]) ?? []
            for volume in volumes {
                guard let remote = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                      remote.scheme == "smb", remote.host == "127.0.0.1", remote.port == port else { continue }
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                catch { return error.localizedDescription }
            }
            return nil
        }.value
    }
}

struct UbuntuDataView: View {
    let config: VMConfig
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job = DeveloperJob()
    @State private var password = ""
    @State private var confirmation = ""
    @State private var local: URL?
    @State private var macPath: String?
    @State private var linux = ""
    @State private var running = true
    @State private var mounting = false
    @State private var problem: String?
    private var busy: Bool { job.busy || mounting }
    private var enabled: Bool { FileManager.default.fileExists(atPath: config.folder.appendingPathComponent("finder-drive.json").path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Files & Sync — \(config.name)").font(.title2.bold()); Spacer(); Button("Close") { dismiss() }.disabled(busy) }
            Text("Finder access and sync start Ubuntu when needed. Disk checkpoints are separate and require Ubuntu to be stopped.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Linux data in Mac Finder") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Full Filesystem shows all stored Linux data read-only. Home lets you edit your Linux files. Finder's Command–Shift–Period shows hidden files.")
                            if !enabled {
                                SecureField("Choose a sharing password (8+ characters)", text: $password)
                                SecureField("Confirm sharing password", text: $confirmation)
                                Button("Enable Finder & Sync") { enable() }.disabled(password.count < 8 || password != confirmation)
                                Text("Installs Samba and rsync in Ubuntu. This password is separate from Ubuntu login and is never saved in app files. For locked environments, provision the Files profile; adding packages to an existing environment can make its lock verification fail.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    Button("Open Full Filesystem") { connect("Root") }
                                    Button("Open Linux Home") { connect("Home") }
                                    Button("Eject Linux Drives") { eject() }
                                }
                                DisclosureGroup("Change sharing password") {
                                    SecureField("New sharing password", text: $password)
                                    SecureField("Confirm", text: $confirmation)
                                    Button("Set Password") { enable() }.disabled(password.count < 8 || password != confirmation)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Mac folder in Ubuntu Files") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(macPath ?? "No Mac folder shared.").textSelection(.enabled)
                            HStack {
                                Button("Choose Mac Folder…") {
                                    if let url = MacFolder.choose(current: MacFolder.path(config)) {
                                        do { try MacFolder.set(url, for: config); macPath = MacFolder.path(config) } catch { problem = error.localizedDescription }
                                    }
                                }.disabled(running)
                                Button("Stop Sharing") { try? MacFolder.set(nil, for: config); macPath = nil }.disabled(running || MacFolder.path(config) == nil)
                            }
                            Text("Choose while the VM is stopped. At the next start, open Ubuntu Files → Home → Mac. It is a live folder: changes affect Mac files immediately. VM checkpoints exclude its contents.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Sync separate copies") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(local?.path ?? "Mac folder not selected").lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose…") { choose() } }
                            TextField("Absolute Linux folder", text: $linux)
                            HStack {
                                Button("Preview Mac → Linux") { sync("to-linux", preview: true) }
                                Button("Sync Mac → Linux") { sync("to-linux", preview: false) }
                            }
                            HStack {
                                Button("Preview Linux → Mac") { sync("to-mac", preview: true) }
                                Button("Sync Linux → Mac") { sync("to-mac", preview: false) }
                            }
                            Text("Copies new and newer files. Newer destination files stay; nothing is deleted. Replaced files go into a timestamped backup folder. Preview again if either side changes before syncing. rsync must be installed in Ubuntu (the Files profile or Enable Finder & Sync supplies it).").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }.disabled(busy)
            }
            if busy { ProgressView(mounting ? "Connecting Finder…" : "Preparing Ubuntu files…") }
            ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90)
        }.padding(22).frame(width: 780, height: 680)
        .onAppear { linux = "/home/\(config.user)/Projects"; macPath = MacFolder.path(config) }
        .task {
            while !Task.isCancelled {
                let folder = config.folder
                let active = await Task.detached { !Storage.busyFolders([folder]).isEmpty }.value
                if Task.isCancelled { return }; running = active
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .interactiveDismissDisabled(busy)
    }
    private func args(_ action: String) -> [String] {
        ["drive", "--vm", config.folder.path, "--qga", config.agentSocket.path, "--project", linux, action]
    }
    private func run(_ arguments: [String], input: Data? = nil, done: (() -> Void)? = nil) {
        if let why = Paths.startProblem(config.folder) { problem = why; return }
        job.run([arguments], root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-"), input: input, finished: done)
    }
    private func connection() -> (Int, String)? {
        guard let line = job.output.split(separator: "\n").last, let data = String(line).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = value["port"] as? Int, (1024...65535).contains(port), let user = value["user"] as? String else { return nil }
        return (port, user)
    }
    private func enable() {
        Task {
            if let port = Self.savedPort(config) {
                mounting = true
                let error = await UbuntuDriveMount.eject(port: port)
                mounting = false
                if let error { problem = error; return }
            }
            setPassword()
        }
    }
    static func savedPort(_ config: VMConfig) -> Int? {
        let file = config.folder.appendingPathComponent("finder-drive.json")
        guard let data = try? Data(contentsOf: file), data.count <= 8192,
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = record["port"] as? Int, (1024...65535).contains(port) else { return nil }
        return port
    }
    private func setPassword() {
        let secret = password
        password = ""; confirmation = ""
        run(args("enable"), input: Data((secret + "\n").utf8)) {
            if job.output.hasPrefix("Completed."), let (port, user) = connection() { mount(port, user, "Root", password: secret) }
        }
    }
    private func connect(_ share: String) {
        run(args("connect")) {
            if job.output.hasPrefix("Completed."), let (port, user) = connection() { mount(port, user, share, password: nil) }
        }
    }
    private func mount(_ port: Int, _ user: String, _ share: String, password: String?) {
        mounting = true
        Task {
            let result = await Task.detached { UbuntuDriveMount.mount(port: port, user: user, share: share, password: password) }.value
            mounting = false; problem = result.error
            if let path = result.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            job.output = result.error == nil ? "Linux \(share) opened in Finder. Eject the Linux drives before stopping Ubuntu." : "The private file connection is ready; Finder did not mount it."
        }
    }
    private func eject() {
        let file = config.folder.appendingPathComponent("finder-drive.json")
        guard let data = try? Data(contentsOf: file), data.count <= 8192, let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let port = record["port"] as? Int else { return }
        mounting = true
        Task {
            let error = await UbuntuDriveMount.eject(port: port)
            mounting = false
            if let error { problem = error }
            else { run(args("disconnect")) }
        }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK { local = panel.url }
    }
    private func sync(_ direction: String, preview: Bool) {
        guard let local else { problem = "Choose a Mac folder first."; return }
        var command = args("sync") + ["--local", local.path, "--direction", direction]
        if preview { command.append("--preview") }
        run(command)
    }
}
