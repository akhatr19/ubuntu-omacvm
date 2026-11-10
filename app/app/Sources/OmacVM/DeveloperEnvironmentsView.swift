import AppKit
import SwiftUI

@MainActor
final class DeveloperJob: ObservableObject {
    @Published var busy = false
    @Published var output = ""

    func run(_ commands: [[String]], root: URL, test: Bool? = nil, finished: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; output = "Working…"
        let cli = DeveloperActions.cli.path
        let app = Bundle.main.bundleURL.path
        let testMode = test ?? TestIdentity.isOn
        Task {
            let result = await Task.detached { () -> String in
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-job-" + UUID().uuidString + ".log")
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    var status: Int32 = 0
                    for args in commands {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: cli)
                        process.arguments = args
                        var env = ProcessInfo.processInfo.environment
                        env["UVM_APP"] = app; env["UVM_VMS_ROOT"] = root.path
                        env["UVM_TEST_MODE"] = testMode ? "1" : "0"
                        process.environment = env
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = handle; process.standardError = handle
                        try process.run()
                        while process.isRunning {
                            if let reader = try? FileHandle(forReadingFrom: file) {
                                let size = (try? reader.seekToEnd()) ?? 0
                                try? reader.seek(toOffset: size > 32768 ? size - 32768 : 0)
                                let progress = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
                                try? reader.close()
                                await MainActor.run { self.output = progress }
                            }
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        process.waitUntilExit()
                        status = process.terminationStatus
                        if status != 0 { break }
                    }
                    let reader = try FileHandle(forReadingFrom: file)
                    defer { try? reader.close() }
                    let size = try reader.seekToEnd()
                    try reader.seek(toOffset: size > 32768 ? size - 32768 : 0)
                    let log = String(decoding: reader.readDataToEndOfFile(), as: UTF8.self)
                    return (status == 0 ? "Completed.\n" : "Failed (\(status)).\n") + log
                } catch { return error.localizedDescription }
            }.value
            output = result; busy = false; finished?()
        }
    }
}

struct DeveloperEnvironmentsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job = DeveloperJob()
    @State private var vms: [VMConfig] = []
    @State private var busyFolders: Set<URL> = []
    @State private var selected: VMConfig?
    @State private var network = false
    @State private var creating = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ubuntu environments").font(.title2.bold())
                Spacer()
                Button("New Environment…") { creating = true }.disabled(job.busy)
                Button("Refresh") { refresh() }
                Button("Close") { dismiss() }.disabled(job.busy)
            }
            Text("Each VM has its own Linux system, disk and SSH identity. Multiple headless environments can run concurrently; the launcher controls one desktop at a time.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vms, id: \.folder) { vm in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                let managed = DeveloperActions.name(vm) != nil
                                HStack {
                                    Text(vm.name).font(.headline)
                                    Spacer()
                                    Text(busyFolders.contains(vm.folder) ? "Running / busy" : "Stopped").foregroundStyle(.secondary)
                                }
                                Text((managed ? "Developer VM" : "Desktop VM") + " · \(vm.cpus) CPUs · \(vm.memoryMB / 1024) GB RAM").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("SSH & Network…") { selected = vm; network = true }
                                    if managed {
                                        Button("Start Headless") { action(vm, "up") }
                                        Button("Stop") { action(vm, "stop") }
                                        Button("Terminal") { open(vm, "shell") }
                                        Button("VS Code") { open(vm, "code") }
                                        Button("Verify") { action(vm, "verify") }
                                    }
                                    Button("Select") {
                                        if state.vmRunning() { problem = "Stop the current desktop VM before selecting another. Headless controls above remain independent." }
                                        else { state.showOther(vm); dismiss() }
                                    }
                                }.disabled(job.busy)
                            }.padding(5)
                        }
                    }
                    if vms.isEmpty { Text("No Ubuntu VMs yet. Create an environment or install Ubuntu from the main setup screen.") }
                }
            }
            if job.busy { ProgressView("Running developer command…") }
            if !job.output.isEmpty {
                ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
            }
        }.padding(22).frame(width: 800, height: 650)
        .onAppear(perform: refresh)
        .task {
            while !Task.isCancelled {
                let folders = vms.map(\.folder)
                let busy = await Task.detached { Storage.busyFolders(folders) }.value
                if Task.isCancelled { return }
                busyFolders = Set(busy)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $network) { if let selected { DeveloperSettingsView(state: state, config: selected) } }
        .sheet(isPresented: $creating, onDismiss: refresh) { NewDeveloperEnvironmentView(root: Paths.vmsRoot) }
        .interactiveDismissDisabled(job.busy)
    }
    private func refresh() {
        vms = VMConfig.all().filter { (try? String(contentsOf: $0.folder.appendingPathComponent("guest-os"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "ubuntu" }
    }
    private func action(_ vm: VMConfig, _ command: String) {
        if let why = Paths.startProblem(vm.folder) { problem = why; return }
        guard let name = DeveloperActions.name(vm) else { return }
        job.run([["--env", name, command]], root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-Dev-"), finished: refresh)
    }
    private func open(_ vm: VMConfig, _ command: String) {
        do { try DeveloperActions.open(vm, command) } catch { problem = error.localizedDescription }
    }
}

struct NewDeveloperEnvironmentView: View {
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job = DeveloperJob()
    @State private var name = "dev"
    @State private var project: URL?
    @State private var base: URL?
    @State private var profiles: Set<String> = ["base", "python"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New developer environment").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.disabled(job.busy)
            }
            Text("Choose a project folder and a frozen Ubuntu base bundle. Initial creation writes uvm.json and uvm.lock.json; an existing manifest and lock are replayed.").foregroundStyle(.secondary)
            TextField("Local environment name", text: $name).disabled(job.busy)
            directory("Project folder", value: project) { project = choose() }
            directory("Base bundle", value: base) { base = choose() }
            Button("Build Base from Ubuntu ISO…") { buildBase() }.disabled(job.busy)
            HStack {
                ForEach(["python", "node", "rust", "docker"], id: \.self) { profile in
                    Toggle(profile.capitalized, isOn: Binding(get: { profiles.contains(profile) }, set: { if $0 { profiles.insert(profile) } else { profiles.remove(profile) } }))
                }
            }.disabled(job.busy)
            Text("Base build tools are always included.").font(.caption).foregroundStyle(.secondary)
            Text("VMs are created in \(root.path). CPU/memory can be changed in the app; project provisioning and package pins are recorded in the manifest and lock.").font(.caption).foregroundStyle(.secondary)
            Button("Create Environment") { create() }
                .buttonStyle(.borderedProminent)
                .disabled(job.busy || project == nil || name.range(of: "^[a-z][a-z0-9-]{0,39}$", options: .regularExpression) == nil)
            if job.busy { ProgressView("Installing packages and configuring Ubuntu…") }
            ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(22).frame(width: 720, height: 540).interactiveDismissDisabled(job.busy)
    }
    private func choose() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func directory(_ title: String, value: URL?, action: @escaping () -> Void) -> some View {
        HStack { Text(title).frame(width: 110, alignment: .leading); Text(value?.path ?? "Not selected").lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose…", action: action).disabled(job.busy) }
    }
    private func buildBase() {
        let input = NSOpenPanel(); input.canChooseDirectories = false; input.canChooseFiles = true
        input.title = "Choose the official Ubuntu 26.10 Desktop ARM64 ISO"
        guard input.runModal() == .OK, let iso = input.url else { return }
        let output = NSSavePanel(); output.title = "Save a new frozen base bundle"
        output.nameFieldStringValue = "UbuntuBase"; output.canCreateDirectories = true
        guard output.runModal() == .OK, let destination = output.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { job.output = "Choose a new destination; existing bundles are never overwritten."; return }
        job.run([["base", "build", "--iso", iso.path, "--output", destination.path]], root: root) {
            if job.output.hasPrefix("Completed.") { base = destination }
        }
    }
    private func create() {
        guard let project else { return }
        let manifest = project.appendingPathComponent("uvm.json")
        var commands: [[String]] = []
        if !FileManager.default.fileExists(atPath: manifest.path) {
            guard let base else { job.output = "Choose a frozen base bundle first. Build one with uvm base build, or use a verified bundle from your team."; return }
            var args = ["init", "--base", base.path, "--name", name, "--output", manifest.path]
            for profile in profiles.sorted() { args += ["--profile", profile] }
            commands.append(args)
        }
        var create = ["--manifest", manifest.path, "create", "--name", name]
        if FileManager.default.fileExists(atPath: project.appendingPathComponent("uvm.lock.json").path) { create.append("--locked") }
        commands.append(create)
        job.run(commands, root: root)
    }
}
