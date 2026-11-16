import AppKit
import SwiftUI

private struct LiveFolder: Decodable, Identifiable {
    let id: String
    let name: String
    let serverRunning: Bool
    let clients: [String]
    let finderPort: Int?
    enum CodingKeys: String, CodingKey { case id, name, clients; case serverRunning = "server_running", finderPort = "finder_port" }
}

private struct SharedConnection: Decodable {
    let id: String
    let folder: String
}

private struct AvailableData: Decodable, Identifiable {
    let id: String
    let name: String
}

struct UbuntuSharedFoldersView: View {
    let config: VMConfig
    let running: Bool
    var onBusy: (Bool) -> Void
    @StateObject private var job = DeveloperJob()
    @State private var folders: [LiveFolder] = []
    @State private var connected: [SharedConnection] = []
    @State private var available: [AvailableData] = []
    @State private var selected = ""
    @State private var source = ""
    @State private var name = "Personal"
    @State private var size = 64
    @State private var password = ""
    @State private var repeated = ""
    @State private var creating = false
    @State private var mounting = false
    @State private var problem: String?
    private var busy: Bool { job.busy || mounting }
    private var current: LiveFolder? { folders.first { $0.id == selected } }
    private var connection: SharedConnection? { connected.first { $0.id == selected } }

    var body: some View {
        GroupBox("Shared folders") {
            VStack(alignment: .leading, spacing: 12) {
                Text("One set of files, live in Mac Finder and any VMs you connect. All can run at the same time.")
                HStack {
                    Picker("Folder", selection: $selected) {
                        Text("Choose a shared folder").tag("")
                        ForEach(folders) { Text($0.name).tag($0.id) }
                    }
                    Button("Refresh") { action(nil) }
                    Button("Create…") { creating.toggle() }
                }
                if let folder = current {
                    HStack {
                        Label(folder.serverRunning ? "File service running" : "Starts automatically when needed", systemImage: folder.serverRunning ? "checkmark.circle.fill" : "moon")
                        Spacer()
                        Text("Shared with \(folder.clients.count) VM\(folder.clients.count == 1 ? "" : "s")")
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open in Finder") { openFinder(folder) }.buttonStyle(.borderedProminent)
                        Button(connection == nil ? "Use in This VM" : "Reconnect") { action("use", extra: ["--id", selected]) }
                        if let connection {
                            Button("Open in Editor") {
                                do { try DeveloperActions.open(config, arguments: DeveloperActions.workspace(config, path: path(connection), action: "code")) }
                                catch { problem = error.localizedDescription }
                            }
                        }
                    }
                    if let connection {
                        HStack {
                            Text(path(connection)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path(connection), forType: .string) }
                        }
                    } else { Text("Use in This VM adds it under ~/Shared without hiding any existing home folders.").font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Manage connections") {
                        ForEach(folder.clients, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).font(.caption) }
                        HStack {
                            Button("Remove from This VM") { action("remove", extra: ["--id", selected]) }.disabled(connection == nil)
                            Button("Stop File Service") { stop(folder) }
                        }
                        Text("Removing a connection preserves the files. Stop is available after connected VMs are stopped and Finder is ejected. The service uses one CPU and up to 2 GB RAM, reclaiming unused memory.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if creating {
                    Divider()
                    Text("Create a shared folder").font(.headline)
                    Picker("Starting data", selection: $source) {
                        Text("Copy this VM’s personal folders to a new disk").tag("")
                        ForEach(available) { Text("Use existing disk: " + $0.name).tag($0.id) }
                    }
                    if source.isEmpty {
                        HStack {
                            TextField("Name", text: $name)
                            Picker("Maximum size", selection: $size) { ForEach([16, 32, 64, 128, 256, 512], id: \.self) { Text("\($0) GB").tag($0) } }.frame(width: 180)
                        }
                    }
                    SecureField("Finder password (8+ characters)", text: $password)
                    SecureField("Confirm Finder password", text: $repeated)
                    Text("First setup needs this VM stopped. A private copy of its system runs the background file service; originals are preserved. Linux clients use private connections automatically. The Finder password is never saved in app files.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create Shared Folder") {
                        var extra = ["--size-gb", String(size), "--name", name]
                        if !source.isEmpty { extra += ["--id", source] }
                        let secret = password; password = ""; repeated = ""
                        action("create", extra: extra, input: Data((secret + "\n").utf8))
                    }.disabled(running || password.count < 8 || password != repeated || (source.isEmpty && name.isEmpty))
                    if running { Text("Stop this VM for initial creation. Once set up, sharing works with VMs running.").font(.caption).foregroundStyle(.orange) }
                }
                if busy { ProgressView(mounting ? "Opening Finder…" : "Connecting shared folders…") }
                if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                if !job.output.isEmpty { Text(String(job.output.suffix(2500))).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(job.output.hasPrefix("Failed") ? .red : .secondary) }
            }.padding(6).disabled(busy)
        }
        .onAppear { action(nil) }
        .onChange(of: busy) { _, value in onBusy(value) }
    }

    private func path(_ connection: SharedConnection) -> String { "/home/\(config.user)/Shared/\(connection.folder)" }
    private func args(_ action: String) -> [String] { ["sharing", "--vm", config.folder.path, "--qga", config.agentSocket.path, action] }
    private func output() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-sharing-" + UUID().uuidString + ".json") }
    private func data(_ file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: file)
    }
    private func action(_ action: String?, extra: [String] = [], input: Data? = nil) {
        guard !busy else { return }
        problem = nil
        let file = output()
        let query = args("list") + ["--output", file.path]
        let commands = action.map { [args($0) + extra, query] } ?? [query]
        let previous = Set(folders.map(\.id))
        job.run(commands, root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-"), input: input) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard job.output.hasPrefix("Completed."), let bytes = data(file),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
            func decode<T: Decodable>(_ key: String, as: T.Type) -> T? {
                guard let value = object[key], let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(T.self, from: bytes)
            }
            guard let rows = decode("folders", as: [LiveFolder].self), let links = decode("connected", as: [SharedConnection].self), let disks = decode("available", as: [AvailableData].self) else { return }
            folders = rows; connected = links; available = disks
            if action == "create", let new = rows.first(where: { !previous.contains($0.id) }) { selected = new.id; creating = false }
            else if !rows.contains(where: { $0.id == selected }) { selected = links.first?.id ?? rows.first?.id ?? "" }
            if let status = object["status"] as? [String: Any], let error = status["error"] as? String { problem = error }
            job.output = action == nil ? "" : "Completed. Shared folders updated."
        }
    }
    private func openFinder(_ folder: LiveFolder) {
        let file = output()
        job.run([args("connect") + ["--id", folder.id, "--output", file.path]], root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-")) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard job.output.hasPrefix("Completed."), let bytes = data(file), let record = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let port = record["port"] as? Int, let user = record["user"] as? String else { return }
            mounting = true
            Task {
                let result = await Task.detached { UbuntuDriveMount.mount(port: port, user: user, share: "Personal", password: nil) }.value
                mounting = false; problem = result.error
                if let path = result.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                job.output = result.error == nil ? "Live folder opened. Mac and Linux edits affect the same files." : ""
            }
        }
    }
    private func stop(_ folder: LiveFolder) {
        mounting = true
        Task {
            var error: String?
            if let port = folder.finderPort { error = await UbuntuDriveMount.eject(port: port) }
            mounting = false
            if let error { problem = error; return }
            action("stop", extra: ["--id", folder.id])
        }
    }
}
