import AppKit
import SwiftUI

struct UbuntuHomeFoldersView: View {
    let config: VMConfig
    let running: Bool
    var onBusy: (Bool) -> Void
    @StateObject private var job = DeveloperJob()
    @State private var enabled = true
    @State private var personalDisk = false
    @State private var root = ""
    @State private var folders: [String] = []
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        GroupBox("Shared home folders") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Use shared folders in this VM", isOn: Binding(get: { enabled }, set: { action($0 ? "enable" : "disable") }))
                    .disabled(running || personalDisk)
                Text("Desktop, Documents, Downloads and any folders you add live in ~/Linux on your Mac. Each enabled distro uses these same files in its home folder. Settings and app data stay private.")
                HStack {
                    Text(root.isEmpty ? "~/Linux" : root).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Open in Finder") { action("prepare") }.disabled(root.isEmpty)
                    Button("Refresh") { action("list") }
                }
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Text("~/Linux/\(folder)  →  ~/\(folder)").font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("Remove") { action("remove", name: folder) }.disabled(running)
                    }
                }
                HStack {
                    TextField("Custom folder, e.g. Developer", text: $name)
                    Button("Add Folder") { action("add", name: name) }.disabled(running || name.isEmpty)
                }
                Text("The folder list applies to all distros after restart. The switch applies only to this VM. Existing Linux files are kept in ~/UbuntuVM Local Folders; turning sharing off restores them. Shared files remain on your Mac and are excluded from VM snapshots.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Changes are live while VMs run. Some apps need polling to notice external edits. File locks are not coordinated across systems; keep databases and apps requiring shared locks on a VM’s private disk.")
                    .font(.caption).foregroundStyle(.secondary)
                if running { Text("Stop this VM to change folder mappings or turn sharing off.").font(.caption).foregroundStyle(.secondary) }
                if personalDisk { Text("This VM uses an existing personal disk. Detach it in Advanced before enabling Mac-backed home folders; its files are preserved.").font(.caption).foregroundStyle(.orange) }
                if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                if job.busy { ProgressView("Updating shared home folders…") }
            }.padding(6).disabled(job.busy)
        }
        .onAppear { action("list") }
        .onChange(of: job.busy) { _, value in onBusy(value) }
    }

    private func action(_ action: String, name: String? = nil) {
        guard !job.busy else { return }
        problem = nil
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-home-settings-" + UUID().uuidString)
        var args = ["home-folders", "--vm", config.folder.path, action, "--output", output.path]
        if let name { args += ["--name", name] }
        job.run([args], root: config.folder.deletingLastPathComponent(), test: config.name.hasPrefix("OmacVM Test-")) {
            defer { try? FileManager.default.removeItem(at: output) }
            guard job.output.hasPrefix("Completed."), let bytes = try? Data(contentsOf: output),
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let path = value["root"] as? String, let names = value["folders"] as? [String], let on = value["enabled"] as? Bool else {
                problem = job.output; return
            }
            root = path; folders = names; enabled = on; personalDisk = value["personal_disk"] as? Bool ?? false
            if action == "add" { self.name = "" }
            if action == "prepare" { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
    }
}
