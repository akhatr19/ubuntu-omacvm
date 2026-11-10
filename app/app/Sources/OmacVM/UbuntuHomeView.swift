import AppKit
import SwiftUI

struct UbuntuHomeView: View {
    @ObservedObject var state: AppState
    @StateObject private var projects = UbuntuProjects()
    @StateObject private var job = DeveloperJob()
    @AppStorage("ubuntuHomeTab") private var tab = 0
    @State private var vms: [VMConfig] = []
    @State private var statuses: [URL: String] = [:]
    @State private var stopping: Set<URL> = []
    @State private var starting: Set<URL> = []
    @State private var network: VMConfig?
    @State private var adding = false
    @State private var creating = false
    @State private var problem: String?
    @State private var containerProjects: Set<String> = []
    var fixtures: [VMConfig]? = nil
    var previewProjects: [UbuntuProject]? = nil

    var body: some View {
        WindowShell {
            WindowHeader(title: "UbuntuVM", facts: "Your Linux machines and projects") { AppIconButton() } trailing: {
                Button("Refresh") { refresh() }
                Button("Add Project…") { tab = 1; adding = true }.disabled(vms.isEmpty || job.busy)
                Menu("New VM") {
                    Button("Ubuntu Desktop from ISO…") {
                        guard !state.vmRunning() else { problem = "Stop the current desktop before installing another."; return }
                        state.config = VMConfig(); state.screen = .setup; state.showHome = false
                    }
                    Button("Reproducible Developer Environment…") { creating = true }
                    Button("Open Existing VM…") { state.openExisting(); refresh() }
                }.disabled(job.busy)
            }
        } notices: {
            if let problem { MessageStrip(text: problem, error: true) { self.problem = nil } }
            if let message = state.message { MessageStrip(text: message, error: !state.messageIsInfo) { state.message = nil } }
        } content: {
            Picker("View", selection: $tab) { Text("VMs").tag(0); Text("Projects").tag(1) }
                .pickerStyle(.segmented).labelsHidden().padding(.bottom, 16)
            if tab == 0 {
                if vms.isEmpty { Text("No Ubuntu VMs yet. Choose New VM to install Ubuntu or create a reproducible environment.").padding(.vertical, 20) }
                ForEach(vms, id: \.folder) { vm in vmCard(vm) }
            } else {
                Text("Projects live inside Ubuntu. Opening a project starts its VM and waits for the connection. Multiple projects can share one VM.")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 14)
                if (previewProjects ?? projects.entries).isEmpty { Text("Choose Add Project to clone a repository, import a Mac folder, or remember an existing Linux folder.").padding(.vertical, 20) }
                ForEach(previewProjects ?? projects.entries) { project in projectCard(project) }
            }
            if job.busy { ProgressView("Starting Ubuntu / preparing your project…").padding(.top, 12) }
            if !job.output.isEmpty {
                ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 110).padding(.top, 12)
            }
        }
        .onAppear { refresh(); if fixtures != nil { tab = previewProjects == nil ? 0 : 1 } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .task {
            while !Task.isCancelled {
                let machines = vms
                let snapshot = await Task.detached { () -> [URL: String] in
                    let busy = Set(Storage.busyFolders(machines.map(\.folder)))
                    return Dictionary(uniqueKeysWithValues: machines.map { vm in
                        let runtime = UbuntuNetworking.runtimeState(vm)
                        let status = !busy.contains(vm.folder) ? "Stopped"
                            : (runtime?["ready"] as? Bool == true ? "Ready" : (DeveloperActions.name(vm) != nil ? "Starting Ubuntu…" : "Desktop running"))
                        return (vm.folder, status)
                    })
                }.value
                if Task.isCancelled { return }
                statuses = snapshot
                stopping = stopping.filter { snapshot[$0] != "Stopped" }
                for folder in stopping { statuses[folder] = "Shutting down…" }
                for folder in starting { statuses[folder] = "Starting Ubuntu…" }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $network) { vm in UbuntuPortsView(state: state, config: vm) }
        .sheet(isPresented: $adding) { AddUbuntuProjectView(vms: vms) { project in projects.remember(project); tab = 1; open(project, action: project.editor) } }
        .sheet(isPresented: $creating, onDismiss: refresh) {
            NewDeveloperEnvironmentView(root: Paths.vmsRoot) { vm in
                refresh(); tab = 1
                let project = UbuntuProject(name: URL(fileURLWithPath: DeveloperActions.projectPath(vm)).lastPathComponent, vmFolder: vm.folder.path, linuxPath: DeveloperActions.projectPath(vm))
                projects.remember(project)
                open(project, action: "code")
            }
        }
    }

    private func vmCard(_ vm: VMConfig) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(vm.name).font(.headline); Spacer(); Text(statuses[vm.folder] ?? "Checking…").foregroundStyle(.secondary) }
                Text("\(vm.cpus) CPUs · \(vm.memoryMB / 1024) GB RAM · \(DeveloperActions.name(vm) == nil ? "Desktop VM" : "Developer environment")").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Start") { start(vm) }.disabled(statuses[vm.folder] != "Stopped")
                    Button("Stop") { stop(vm) }.disabled(statuses[vm.folder] == "Stopped")
                    Button("Terminal") { terminal(vm, path: "/home/\(vm.user)") }
                    Button("Open Desktop") { desktop(vm) }
                    Button("VS Code") { run(vm, path: "/home/\(vm.user)", action: "code") }
                    Menu("More") {
                        Button("Ports & SSH…") { network = vm }
                        Button("VM Settings…") {
                            if state.vmRunning() && state.config.folder != vm.folder { problem = "Stop the current desktop before selecting another VM." }
                            else { state.showOther(vm); state.showHome = false }
                        }
                    }.fixedSize()
                }.disabled(job.busy)
            }.padding(8)
        }.padding(.bottom, 12).layoutProbe("home-vm-\(vm.id)")
    }

    private func projectCard(_ project: UbuntuProject) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(project.name).font(.headline); Spacer(); Text(vms.first { $0.folder.path == project.vmFolder }?.name ?? "VM unavailable").foregroundStyle(.secondary) }
                Text(project.linuxPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let date = project.lastOpened { Text("Last used \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Open Project") { open(project, action: project.editor) }.buttonStyle(.borderedProminent)
                    Button("Terminal") { open(project, action: "terminal") }
                    Button("VS Code") { open(project, action: "code") }
                    if containerProjects.contains(project.vmFolder + project.linuxPath) {
                        Button("Dev Container…") { open(project, action: "container") }
                    }
                    Menu("Files & Environment") {
                        Button("Check Project / Dev Container") { open(project, action: "info") }
                        Button("Open Dev Container…") { open(project, action: "container") }
                        Button("Import Mac Folder…") { importFolder(project) }
                        Button("Export Project Archive…") { export(project) }
                        Button("Verify Environment Lock") { verify(project) }
                        Button("Ports & SSH…") { network = vms.first { $0.folder.path == project.vmFolder } }
                        Button("Forget Project") { projects.entries.removeAll { $0.id == project.id } }
                    }.fixedSize()
                }.disabled(job.busy || !vms.contains { $0.folder.path == project.vmFolder })
                Text("Forget removes this shortcut only. Your Linux files stay in the VM.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.padding(.bottom, 12)
    }

    private func refresh() {
        let candidates = fixtures ?? VMConfig.all().filter {
            (try? String(contentsOf: $0.folder.appendingPathComponent("guest-os"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "ubuntu"
        }
        var seen: Set<String> = []
        vms = candidates.filter { seen.insert($0.folder.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }
    private func run(_ vm: VMConfig, path: String, action: String, source: String? = nil) {
        if let why = Paths.startProblem(vm.folder) { problem = why; return }
        var commands = [DeveloperActions.workspace(vm, path: path, action: action, source: source)]
        if action == "code" || action == "container" { commands.append(DeveloperActions.workspace(vm, path: path, action: "info")) }
        job.run(commands, root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-")) {
            guard job.output.hasPrefix("Completed."), let line = job.output.split(separator: "\n").last,
                  let data = String(line).data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let container = info["devcontainer"] as? Bool == true
            if container { containerProjects.insert(vm.folder.path + path) }
            else { containerProjects.remove(vm.folder.path + path) }
            job.output = "Ubuntu connected. Project folder \(info["exists"] as? Bool == true ? "found" : "not found").\nDev Container: \(container ? "configuration available" : "no configuration in this project")."
            if container { job.output += "\nIn VS Code, choose Dev Containers: Reopen in Container. Docker in Ubuntu and the Remote - SSH / Dev Containers extensions are required." }
        }
    }
    private func terminal(_ vm: VMConfig, path: String) {
        do { try DeveloperActions.terminal(vm, path: path) } catch { problem = error.localizedDescription }
    }
    private func start(_ vm: VMConfig) {
        if let name = DeveloperActions.name(vm) {
            if let why = Paths.startProblem(vm.folder) { problem = why; return }
            starting.insert(vm.folder)
            job.run([["--env", name, "up"]], root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-")) { starting.remove(vm.folder) }
        } else { desktop(vm) }
    }
    private func desktop(_ vm: VMConfig) {
        if DeveloperActions.name(vm) != nil {
            if UbuntuNetworking.showDesktop(vm) { return }
            if statuses[vm.folder] == "Ready" {
                let alert = NSAlert(); alert.messageText = "Restart \(vm.name) with a desktop?"
                alert.informativeText = "This restarts the headless VM. Active terminals and services will disconnect briefly."
                alert.addButton(withTitle: "Restart and Open"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
            guard let name = DeveloperActions.name(vm) else { return }
            if let why = Paths.startProblem(vm.folder) { problem = why; return }
            job.run([["--env", name, "desktop"]], root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-"))
        } else {
            guard !state.vmRunning() || state.config.folder == vm.folder else { problem = "A desktop is already open. Stop it before opening another."; return }
            state.showOther(vm); state.startVM()
        }
    }
    private func stop(_ vm: VMConfig) {
        if let why = Paths.startProblem(vm.folder) { problem = why; return }
        if let name = DeveloperActions.name(vm) {
            stopping.insert(vm.folder)
            job.run([["--env", name, "stop"]], root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-")) {
                if !job.output.hasPrefix("Completed.") { stopping.remove(vm.folder) }
            }
        } else {
            let socket = vm.qmpSocket.path
            Task {
                let error = await Task.detached { () -> String? in
                    do { let qmp = try QMPConnection(socketPath: socket, identifierPrefix: "home-stop"); defer { qmp.close() }; _ = try qmp.execute("system_powerdown"); return nil }
                    catch { return error.localizedDescription }
                }.value
                problem = error
                if error != nil { stopping.remove(vm.folder) }
            }
            stopping.insert(vm.folder)
        }
        statuses[vm.folder] = "Shutting down…"
    }
    private func open(_ project: UbuntuProject, action: String) {
        guard let vm = vms.first(where: { $0.folder.path == project.vmFolder }) else { return }
        if action == "terminal" { terminal(vm, path: project.linuxPath) }
        else { run(vm, path: project.linuxPath, action: action) }
        if ["code", "container", "terminal"].contains(action) {
            var recent = project; recent.lastOpened = Date(); projects.remember(recent)
        }
    }
    private func importFolder(_ project: UbuntuProject) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url, let vm = vms.first(where: { $0.folder.path == project.vmFolder }) { run(vm, path: project.linuxPath, action: "import", source: url.path) }
    }
    private func export(_ project: UbuntuProject) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + ".tar.gz"
        if panel.runModal() == .OK, let url = panel.url, let vm = vms.first(where: { $0.folder.path == project.vmFolder }) { run(vm, path: project.linuxPath, action: "export", source: url.path) }
    }
    private func verify(_ project: UbuntuProject) {
        guard let vm = vms.first(where: { $0.folder.path == project.vmFolder }), let name = DeveloperActions.name(vm) else { problem = "This desktop VM has no reproducible environment lock. Create a developer environment to use locked provisioning."; return }
        if let why = Paths.startProblem(vm.folder) { problem = why; return }
        job.run([["--manifest", vm.folder.appendingPathComponent("definition/uvm.json").path, "--env", name, "verify"]], root: vm.folder.deletingLastPathComponent(), test: vm.name.hasPrefix("OmacVM Test-"))
    }
}

// VMConfig's stable folder is also its sheet identity.
extension VMConfig: Identifiable {}
