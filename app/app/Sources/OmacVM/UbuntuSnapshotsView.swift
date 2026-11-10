import AppKit
import SwiftUI

struct UbuntuCheckpoint: Decodable, Identifiable {
    let id: String
    let parent: String?
    let label: String
    let vmName: String
    let createdAt: String
    enum CodingKeys: String, CodingKey { case id, parent, label; case vmName = "vm_name", createdAt = "created_at" }
}

struct UbuntuSnapshotsView: View {
    let config: VMConfig
    var previewRows: [UbuntuCheckpoint]? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job = DeveloperJob()
    @State private var rows: [UbuntuCheckpoint] = []
    @State private var head: String?
    @State private var name = "Checkpoint"
    @State private var branch = "branch"
    @State private var selected: String?
    @State private var restoring = false
    @State private var running = true
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Snapshots — \(config.name)").font(.title2.bold()); Spacer(); Button("Refresh") { refresh() }.disabled(job.busy); Button("Close") { dismiss() }.disabled(job.busy) }
            Text("Disk checkpoints include Ubuntu, installed tools, files and compute/display settings. Stop the VM first. RAM and shared Mac data are excluded; Mac sharing/network choices stay local.").foregroundStyle(.secondary)
            if running { Text("Close this panel and stop the VM from its card before creating or restoring a checkpoint.").foregroundStyle(.orange) }
            HStack { TextField("Checkpoint name", text: $name); Button("Create Checkpoint") { action("create", extra: ["--name", name]) }.disabled(running || loading || job.busy || name.isEmpty) }
            List(rows, selection: $selected) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(row.label).font(.headline); if row.id == head { Text("Current branch point").font(.caption).foregroundStyle(.orange) } }
                    Text("\(row.vmName) · \(row.createdAt)").font(.caption).foregroundStyle(.secondary)
                    Text("\(row.id.prefix(8)) ← \(row.parent.map { String($0.prefix(8)) } ?? "root")").font(.system(.caption, design: .monospaced))
                }.padding(.vertical, 4).tag(row.id)
            }
            HStack {
                TextField("New VM branch name", text: $branch)
                Button("Fork New VM") { if let selected { action("fork", extra: ["--id", selected, "--name", branch]) } }.disabled(selected == nil || branch.isEmpty || job.busy)
                Button("Restore…") { restoring = true }.disabled(selected == nil || running || job.busy)
            }
            Text("Forks get new management keys, ports and machine identity. Mac folder sharing and published services start off. Restoring saves the current disk as a checkpoint first.").font(.caption).foregroundStyle(.secondary)
            Text("RAM save/resume is unavailable with this accelerated GPU runtime: it rejects device migration.").font(.caption).foregroundStyle(.secondary)
            if job.busy { ProgressView("Working on VM disks…") }
            ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 80)
        }.padding(22).frame(width: 780, height: 620)
        .onAppear {
            if let previewRows { rows = previewRows; head = previewRows.first?.id; running = false; loading = false }
            else { refresh() }
        }
        .task {
            guard previewRows == nil else { return }
            while !Task.isCancelled {
                let folder = config.folder
                let busy = await Task.detached { !Storage.busyFolders([folder]).isEmpty }.value
                if Task.isCancelled { return }; running = busy
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog("Restore this checkpoint? The current disk is preserved first. Shared Mac data is unchanged.", isPresented: $restoring) {
            Button("Preserve Current State and Restore") { if let selected { action("restore", extra: ["--id", selected]) } }
        }
        .interactiveDismissDisabled(job.busy)
    }
    private func refresh() {
        guard !job.busy else { return }
        action("list", extra: [])
    }
    private func action(_ action: String, extra: [String]) {
        if let why = Paths.startProblem(config.folder) { job.output = why; return }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-checkpoints-" + UUID().uuidString + ".json")
        let query = ["snapshot", "--vm", config.folder.path, "list", "--output", output.path]
        let commands = action == "list" ? [query] : [["snapshot", "--vm", config.folder.path, action] + extra, query]
        job.run(commands, root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-")) {
            loading = false
            defer { try? FileManager.default.removeItem(at: output) }
            guard job.output.hasPrefix("Completed."), let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 8 * 1024 * 1024, let data = try? Data(contentsOf: output),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let objects = result["checkpoints"], let encoded = try? JSONSerialization.data(withJSONObject: objects),
                  let decoded = try? JSONDecoder().decode([UbuntuCheckpoint].self, from: encoded) else { return }
            rows = decoded; head = result["head"] as? String
            job.output = action == "list" ? "Select a checkpoint to restore or create a new VM branch." : (action == "fork" ? "Fork created. Close this panel to find the new VM on the home screen." : "Completed. Your checkpoint history is updated.")
        }
    }
}
