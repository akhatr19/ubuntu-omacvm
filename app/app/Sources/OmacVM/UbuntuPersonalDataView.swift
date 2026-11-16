import SwiftUI

private struct PersonalDisk: Decodable, Identifiable {
    let id: String
    let name: String
    let sizeGb: Int
    let attachedVm: String?
    let initialized: Bool
    let shared: Bool?
    enum CodingKeys: String, CodingKey { case id, name, initialized, shared; case sizeGb = "size_gb", attachedVm = "attached_vm" }
}

private struct PersonalSnapshot: Decodable, Identifiable {
    let snapshotId: String
    let snapshotName: String
    var id: String { snapshotId }
    enum CodingKeys: String, CodingKey { case snapshotId = "snapshot_id", snapshotName = "snapshot_name" }
}

struct UbuntuPersonalDataView: View {
    let config: VMConfig
    let running: Bool
    var onBusy: (Bool) -> Void
    @StateObject private var job = DeveloperJob()
    @State private var disks: [PersonalDisk] = []
    @State private var snapshots: [PersonalSnapshot] = []
    @State private var selected = ""
    @State private var attached: String?
    @State private var snapshot = ""
    @State private var name = "Personal"
    @State private var size = 64
    @State private var snapshotName = "Before changes"
    @State private var forkName = "Personal fork"
    @State private var folders: Set<String> = ["Projects", "Documents", "Downloads", "Pictures", "Music", "Videos"]
    @State private var confirm: String?
    private var disk: PersonalDisk? { disks.first { $0.id == selected } }
    private let folderNames = ["Projects", "Documents", "Downloads", "Pictures", "Music", "Videos"]

    var body: some View {
        GroupBox("Personal data across VMs") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Keep projects and personal files on a separate Linux disk. Each distro keeps its own desktop settings, apps and caches. Deleting a VM preserves these data disks.")
                HStack {
                    Picker("Data disk", selection: $selected) {
                        Text("Select a disk").tag("")
                        ForEach(disks) { disk in Text("\(disk.name) · \(disk.sizeGb) GB max").tag(disk.id) }
                    }
                    Button("Refresh") { refresh() }
                }
                if let disk {
                    Text(disk.attachedVm.map { "Attached to \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Detached — available for another VM")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Folders to share") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
                            ForEach(folderNames, id: \.self) { folder in
                                Toggle(folder, isOn: Binding(get: { folders.contains(folder) }, set: { if $0 { folders.insert(folder) } else { folders.remove(folder) } }))
                            }
                        }
                        Text("First setup copies these folders to a new disk. Originals stay on this VM. Attaching existing data temporarily hides the local versions; detaching brings them back. Configuration and credentials stay local.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(attached == selected ? "Repair / Reconfigure…" : "Attach & Set Up…") { confirm = "attach" }
                            .disabled(running || folders.isEmpty || disk.shared == true)
                        Button("Detach…") { confirm = "detach" }.disabled(running || attached != selected)
                    }
                    Text("Stop the VM first. Setup uses a private maintenance boot and returns it to a stopped state. Attaching automatically releases a stopped previous VM. For simultaneous access, use Shared Folders above.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Data snapshots & forks") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Snapshot name", text: $snapshotName)
                                Button("Create Data Snapshot") { action("snapshot", extra: ["--id", selected, "--name", snapshotName]) }.disabled(running || !disk.initialized || snapshotName.isEmpty)
                            }
                            Picker("Snapshot", selection: $snapshot) {
                                Text("Select a snapshot").tag("")
                                ForEach(snapshots) { Text($0.snapshotName).tag($0.id) }
                            }
                            HStack {
                                TextField("Fork name", text: $forkName)
                                Button("Fork Data") { action("fork", extra: ["--id", selected, "--snapshot-id", snapshot, "--name", forkName]) }.disabled(snapshot.isEmpty || forkName.isEmpty)
                                Button("Restore…") { confirm = "restore" }.disabled(snapshot.isEmpty || disk.attachedVm != nil)
                            }
                            Text("Snapshots contain personal data only. Restore requires detaching and preserves the current data first. Forks are independent copies; changes are not merged automatically. VM snapshots exclude this disk.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Create a data disk") {
                    HStack {
                        TextField("Name", text: $name)
                        Picker("Maximum size", selection: $size) { ForEach([16, 32, 64, 128, 256, 512], id: \.self) { Text("\($0) GB").tag($0) } }.frame(width: 180)
                        Button("Create Disk") { action("create", extra: ["--name", name, "--size-gb", String(size)]) }.disabled(name.isEmpty)
                    }
                    Text("Grows as files are written. Select the new disk above, then Attach & Set Up. Creating a disk does not change this VM.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if job.busy { ProgressView("Working on personal data…") }
                if !job.output.isEmpty {
                    Text(String(job.output.suffix(3000))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(job.output.hasPrefix("Failed") ? .red : .secondary)
                }
            }.padding(6).disabled(job.busy)
        }
        .onAppear { refresh() }
        .onChange(of: selected) { _, _ in loadSnapshots() }
        .onChange(of: job.busy) { _, value in onBusy(value) }
        .confirmationDialog(confirmation, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if confirm == "attach" {
                Button("Set Up Personal Folders") { action("attach", extra: ["--id", selected] + folderNames.filter { folders.contains($0) }.flatMap { ["--folder", $0] }); confirm = nil }
            } else if confirm == "detach" {
                Button("Detach and Restore Local Folders") { action("detach"); confirm = nil }
            } else {
                Button("Preserve Current Data and Restore") { action("restore", extra: ["--id", selected, "--snapshot-id", snapshot]); confirm = nil }
            }
        }
    }

    private var confirmation: String {
        if confirm == "attach" { return "Set up personal folders for \(config.name)? Local originals are preserved. An existing data disk keeps its own files. The VM will boot privately and shut down." }
        if confirm == "detach" { return "Detach personal data? This VM’s original local folders become visible again. Shared data stays on its separate disk." }
        return "Restore personal data? The current data disk is snapshotted first. System disks are unchanged."
    }

    private func args(_ action: String) -> [String] { ["data", "--vm", config.folder.path, action] }

    private func refresh() { action(nil) }

    private func action(_ action: String?, extra: [String] = []) {
        guard !job.busy else { return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-data-" + UUID().uuidString + ".json")
        let query = args("list") + ["--output", output.path]
        let commands = action.map { [args($0) + extra, query] } ?? [query]
        job.run(commands, root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-")) {
            defer { try? FileManager.default.removeItem(at: output) }
            guard job.output.hasPrefix("Completed."), let data = bounded(output),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = result["volumes"], let encoded = try? JSONSerialization.data(withJSONObject: rows),
                  let decoded = try? JSONDecoder().decode([PersonalDisk].self, from: encoded) else { return }
            disks = decoded; attached = result["attached"] as? String
            if let saved = result["folders"] as? [String] { folders = Set(saved.filter { folderNames.contains($0) }) }
            if !disks.contains(where: { $0.id == selected }) { selected = attached ?? disks.first?.id ?? "" }
            job.output = action == nil ? "" : "Completed. Personal data library updated."
            loadSnapshots()
        }
    }

    private func loadSnapshots() {
        guard !selected.isEmpty, !job.busy else { snapshots = []; snapshot = ""; return }
        let identity = selected
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-data-snapshots-" + UUID().uuidString + ".json")
        job.run([args("snapshots") + ["--id", identity, "--output", output.path]], root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-")) {
            defer { try? FileManager.default.removeItem(at: output) }
            guard selected == identity, job.output.hasPrefix("Completed."), let data = bounded(output),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = result["snapshots"], let encoded = try? JSONSerialization.data(withJSONObject: rows),
                  let decoded = try? JSONDecoder().decode([PersonalSnapshot].self, from: encoded) else { return }
            snapshots = decoded
            if !snapshots.contains(where: { $0.id == snapshot }) { snapshot = snapshots.first?.id ?? "" }
            job.output = ""
        }
    }

    private func bounded(_ file: URL) -> Data? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: file)
    }
}
