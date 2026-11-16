import AppKit
import SwiftUI

struct AddUbuntuProjectView: View {
    let vms: [VMConfig]
    var completed: (UbuntuProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job = DeveloperJob()
    @State private var vmFolder = ""
    @State private var name = ""
    @State private var path = ""
    @State private var source = "existing"
    @State private var repository = ""
    @State private var macFolder: URL?
    @State private var editor = "code"
    private var vm: VMConfig? { vms.first { $0.folder.path == vmFolder } }
    private var linuxPath: String { path.isEmpty ? "/home/\(vm?.user ?? "ubuntu")/Projects/\(name)" : path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Add a Linux project").font(.title2.bold()); Spacer(); Button("Close") { dismiss() }.disabled(job.busy) }
            Text("Choose a VM to share, then clone, import, create or attach a Linux folder. To get separate pinned tools, create a reproducible developer environment from New VM.").foregroundStyle(.secondary)
            Form {
                TextField("Project name", text: $name)
                Picker("Ubuntu VM", selection: $vmFolder) { ForEach(vms, id: \.folder) { Text($0.name).tag($0.folder.path) } }
                Picker("Project source", selection: $source) {
                    Text("Existing Linux folder").tag("existing")
                    Text("Git repository").tag("clone")
                    Text("Import Mac folder").tag("import")
                    Text("Empty project").tag("init")
                }
                TextField("Linux folder", text: Binding(get: { linuxPath }, set: { path = $0 }))
                if source == "clone" {
                    TextField("HTTPS or git@host:repo URL", text: $repository)
                    Text("Git is installed if needed in a desktop VM. Developer environments use their provisioned tools.").font(.caption).foregroundStyle(.secondary)
                }
                if source == "import" {
                    HStack {
                        Text(macFolder?.path ?? "Choose a Mac folder") .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                            if panel.runModal() == .OK { macFolder = panel.url; if name.isEmpty { name = panel.url?.lastPathComponent ?? "" } }
                        }
                    }
                }
                Picker("Open with", selection: $editor) { Text("VS Code").tag("code"); Text("Terminal").tag("terminal") }
            }.disabled(job.busy)
            Text("Import copies files once; it does not synchronize or delete either folder. Existing Linux files are kept. Projects remain on Linux storage for builds and file watching.").font(.caption).foregroundStyle(.secondary)
            Button("Add & Open Project") { add() }.buttonStyle(.borderedProminent)
                .disabled(job.busy || vm == nil || name.isEmpty || name.contains("/") || name.utf8.count > 80 || (source == "clone" && repository.isEmpty) || (source == "import" && macFolder == nil))
            if job.busy { ProgressView("Starting Ubuntu / preparing project…") }
            ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
        }.padding(22).frame(width: 700, height: 540)
        .onAppear { vmFolder = vms.first?.folder.path ?? "" }
        .interactiveDismissDisabled(job.busy)
    }
    private func add() {
        guard let vm else { return }
        if let why = Paths.startProblem(vm.folder) { job.output = why; return }
        var commands: [[String]] = []
        if source != "existing" {
            commands.append(DeveloperActions.workspace(vm, path: linuxPath, action: source, source: source == "clone" ? repository : macFolder?.path))
        }
        commands.append(DeveloperActions.workspace(vm, path: linuxPath, action: "info"))
        let project = UbuntuProject(name: name, vmFolder: vm.folder.path, linuxPath: linuxPath, editor: editor)
        job.run(commands, root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-")) {
            guard job.output.hasPrefix("Completed.") else { return }
            let last = job.output.split(separator: "\n").last.map(String.init) ?? ""
            guard let data = last.data(using: .utf8), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], info["exists"] as? Bool == true else { job.output = "Linux folder does not exist. Choose Clone, Import or Empty project to create it."; return }
            completed(project); dismiss()
        }
    }
}
