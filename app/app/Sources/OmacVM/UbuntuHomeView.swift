import AppKit
import SwiftUI
import OmacVMFeatures

struct UbuntuHomeView: View {
    @ObservedObject var state: AppState
    @StateObject private var projects = UbuntuProjects()
    @StateObject private var job = DeveloperJob()
    @AppStorage("ubuntuHomeTab") private var tab = 0
    @State private var vms: [VMConfig] = []
    @State private var statuses: [URL: String] = [:]
    @State private var stopping: Set<URL> = []
    @State private var starting: Set<URL> = []
    @State private var selectedFolder: URL?
    @State private var section = VMSection.overview
    @State private var editorSettings = false
    @State private var editorLabel = UbuntuEditorSettings.label
    @State private var detailBusy = false
    @State private var activityExpanded = false
    @State private var pendingDelete: VMConfig?
    @State private var deleteBusy = false
    private enum VMSection: String, CaseIterable {
        case overview = "Overview", projects = "Projects", network = "Connections", files = "Files", snapshots = "Snapshots", resources = "Resources", input = "Input"
    }
    private var selectedVM: VMConfig? { vms.first { $0.folder == selectedFolder } ?? vms.first }
    private var busy: Bool { job.busy || detailBusy }

    @State private var adding = false
    @State private var creating = false
    @State private var problem: String?
    @State private var containerProjects: Set<String> = []
    var fixtures: [VMConfig]? = nil
    var previewProjects: [UbuntuProject]? = nil
    var previewSection: String? = nil
    var previewRunning = false

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "UbuntuVM", facts: "Your Linux machines and projects") { AppIconButton() } trailing: {
                Button("App Settings…") { editorSettings = true }.disabled(busy)
                Button("Add Project…") { tab = 1; adding = true }.disabled(vms.isEmpty || busy)
                Menu("New VM") {
                    ForEach(GuestProfile.allCases) { guest in
                        Button("\(guest.title)…") {
                            guard !state.vmRunning() else { problem = "Stop the current desktop before installing another."; return }
                            var config = VMConfig(); config.guest = guest; config.name = guest.title
                            state.config = config; state.screen = .setup; state.showHome = false
                        }
                    }
                    Button("Reproducible Environment…") { creating = true }
                    Button("Open Existing VM…") { state.openExisting(); refresh() }
                }.disabled(busy)
            }
            if let problem { MessageStrip(text: problem, error: true) { self.problem = nil } }
            if let message = state.message { MessageStrip(text: message, error: !state.messageIsInfo) { state.message = nil } }
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 165)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if tab == 1 {
                        ScrollView { VStack(alignment: .leading, spacing: 14) {
                            Text("Projects").font(.title.bold())
                            Text("Opening a project starts its VM if needed, waits for SSH, then opens your chosen editor.").foregroundStyle(.secondary)
                            if shownProjects.isEmpty { Text("Add a project to clone a repository, import a Mac folder, or remember a Linux folder.").padding(.vertical) }
                            ForEach(shownProjects) { project in projectCard(project) }
                        }.padding(22) }
                    } else if let vm = selectedVM {
                        vmHeader(vm).padding(20)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 4)], spacing: 4) {
                            ForEach(VMSection.allCases, id: \.self) { item in
                                Button { section = item } label: {
                                    Text(item.rawValue).font(.system(size: 12, weight: section == item ? .semibold : .regular))
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(section == item ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 20).disabled(busy)
                        Divider().padding(.top, 8)
                        vmContent(vm).id(vm.folder)
                    } else {
                        ContentUnavailableView("No VMs", systemImage: "desktopcomputer", description: Text("Choose Ubuntu, Omarchy, a custom ISO or a developer environment from New VM."))
                    }
                    if job.busy { ProgressView("Preparing Ubuntu…").padding(12) }
                    if !job.output.isEmpty {
                        DisclosureGroup("Activity", isExpanded: $activityExpanded) {
                            ScrollView { Text(job.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
                        }.padding(12)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack { Text("Opening UbuntuVM shows this launcher. VMs keep running independently."); Spacer(); Text(Product.buildLabel) }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .tint(Color(red: 0.78, green: 0.30, blue: 0.12))
        .onChange(of: job.busy) { _, value in
            if value { activityExpanded = true }
            else if job.output.hasPrefix("Failed") { problem = String(job.output.suffix(2000)) }
        }
        .onAppear { refresh(); if fixtures != nil { tab = previewProjects == nil ? 0 : 1 }; if let previewSection, let value = VMSection(rawValue: previewSection) { tab = 0; section = value } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh(); editorLabel = UbuntuEditorSettings.label }
        .task {
            guard fixtures == nil else { return }
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
        .sheet(item: $pendingDelete, onDismiss: refresh) { vm in
            DeleteSheet(vm: vm, size: state.storage.vms.first(where: { $0.folder == vm.folder })?.size, running: deleteBusy) { confirmed in
                pendingDelete = nil
                if confirmed { state.storage.trash(vm); refresh() }
            }
        }
        .sheet(isPresented: $editorSettings) { UbuntuEditorSettingsView { editorLabel = UbuntuEditorSettings.label } }
        .sheet(isPresented: $adding) { AddUbuntuProjectView(vms: vms) { project in projects.remember(project); tab = 1; open(project, action: project.editor) } }
        .sheet(isPresented: $creating, onDismiss: refresh) {
            NewDeveloperEnvironmentView(root: Paths.vmsRoot) { vm in
                refresh(); tab = 1
                let project = UbuntuProject(name: URL(fileURLWithPath: DeveloperActions.projectPath(vm)).lastPathComponent, vmFolder: vm.folder.path, linuxPath: DeveloperActions.projectPath(vm))
                projects.remember(project); open(project, action: "code")
            }
        }
    }
    private var shownProjects: [UbuntuProject] { previewProjects ?? projects.entries }
    private var openLabel: String { editorLabel == "VS Code Insiders" ? "Open in Insiders" : "Open in VS Code" }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { tab = 1 } label: { Label("Projects", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                .buttonStyle(.plain).background(tab == 1 ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            Text("VIRTUAL MACHINES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 16)
            ScrollView { VStack(alignment: .leading, spacing: 8) {
            ForEach(vms, id: \.folder) { vm in
                Button { select(vm, section: .overview) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.name).font(.callout).lineLimit(2)
                        Text(statuses[vm.folder] ?? "Checking…").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                }.buttonStyle(.plain)
                    .background(tab == 0 && selectedVM?.folder == vm.folder ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
            } }
            Spacer()
            Button("Refresh VMs") { refresh() }.buttonStyle(.borderless)
            Divider()
            Text("Default editor").font(.caption).foregroundStyle(.secondary)
            Button(editorLabel + " · Change…") { editorSettings = true }.buttonStyle(.borderless).multilineTextAlignment(.leading)
        }.padding(12).frame(maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .controlBackgroundColor)).disabled(busy)
    }
    private func select(_ vm: VMConfig, section: VMSection) { selectedFolder = vm.folder; tab = 0; self.section = section }
    private func vmHeader(_ vm: VMConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(vm.name).font(.title.bold()); Spacer(); Text(statuses[vm.folder] ?? "Checking…").foregroundStyle(.secondary) }
            Text("\(vm.cpus) CPUs · \(vm.memoryMB / 1024) GB RAM · \(vm.guest.title)\(DeveloperActions.name(vm) == nil ? "" : " developer environment")").font(.caption).foregroundStyle(.secondary)
            HStack {
                if vm.guest.integrated {
                    Button(openLabel) { run(vm, path: "/home/\(vm.user)", action: "code") }.buttonStyle(.borderedProminent)
                    Button("Terminal") { terminal(vm, path: "/home/\(vm.user)") }
                    Button("All VM Settings…") { state.showOther(vm); state.showHome = false }
                }
                Button("Show Desktop") { desktop(vm) }
                Spacer()
                Button(statuses[vm.folder] == "Stopped" ? "Start VM" : "Stop VM") {
                    if statuses[vm.folder] == "Stopped" { start(vm) } else { stop(vm) }
                }.disabled(statuses[vm.folder] == nil || stopping.contains(vm.folder))
            }.disabled(busy)
        }.layoutProbe("home-vm-\(vm.id)")
    }
    @ViewBuilder private func vmContent(_ vm: VMConfig) -> some View {
        if vm.isCustom && section != .snapshots && section != .resources {
            CustomGuestView(state: state, config: vm, running: statuses[vm.folder] != "Stopped")
        } else {
        switch section {
        case .network:
            VStack(spacing: 0) {
                if DeveloperActions.name(vm) == nil {
                    DisclosureGroup("Advanced network engine") {
                        UbuntuVMControls(config: vm, running: statuses[vm.folder] != "Stopped", pane: .network)
                    }.padding(.horizontal, 20).padding(.top, 12)
                }
                UbuntuPortsView(state: state, config: vm, embedded: true)
            }
        case .files: UbuntuDataView(config: vm, embedded: true, onBusy: { detailBusy = $0 })
        case .snapshots: UbuntuSnapshotsView(config: vm, embedded: true, onChanged: refresh, onBusy: { detailBusy = $0 })
        case .resources, .input:
            ScrollView {
                UbuntuVMControls(config: vm, running: statuses[vm.folder] != "Stopped", pane: section == .input ? .input : .resources, helperBusy: state.vmRunning(), update: { features in
                    guard !state.vmRunning() || state.config.folder == vm.folder else { problem = "Stop the other desktop before updating this VM's guest integration."; return }
                    state.showOther(VMConfig.load(from: vm.folder) ?? vm); state.updateVM(features: features)
                }, changed: refresh, storage: state.storage, openVM: { state.openExisting(); refresh() }, deleteVM: { vm in
                    deleteBusy = statuses[vm.folder] != "Stopped"; pendingDelete = vm
                }).padding(20)
            }
        case .overview, .projects:
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Text("Projects on this VM").font(.headline)
                let entries = shownProjects.filter { $0.vmFolder == vm.folder.path }
                if entries.isEmpty {
                    Text("Add a Linux project to open its exact folder in your editor.").foregroundStyle(.secondary)
                    Button("Add Project…") { adding = true }
                    Button("Open Linux Home in Editor") { run(vm, path: "/home/\(vm.user)", action: "code") }
                }
                ForEach(entries) { project in projectCard(project) }
                if section == .overview {
                    HStack {
                        GroupBox("Connections") {
                            VStack(alignment: .leading, spacing: 8) { Text("SSH, LAN access and published ports"); Button("Manage Connections →") { section = .network } }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        }
                        GroupBox("Resources") {
                            VStack(alignment: .leading, spacing: 8) { Text("\(vm.cpus) CPUs · \(vm.memoryMB / 1024) GB RAM"); Button("Configure Resources →") { section = .resources } }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        }
                    }
                }
            }.padding(20) }
        }
        }
    }
    private func projectCard(_ project: UbuntuProject) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(project.name).font(.headline); Spacer(); Text(vms.first(where: { $0.folder.path == project.vmFolder })?.name ?? "VM unavailable").foregroundStyle(.secondary) }
                Text(project.linuxPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button(project.editor == "code" ? openLabel : "Open Project") { open(project, action: project.editor) }.buttonStyle(.borderedProminent)
                    Button("Terminal") { open(project, action: "terminal") }
                    if project.editor != "code" { Button(openLabel) { open(project, action: "code") } }
                    if containerProjects.contains(project.vmFolder + project.linuxPath) { Button("Dev Container…") { open(project, action: "container") } }
                    Button("VM Controls →") { if let vm = vms.first(where: { $0.folder.path == project.vmFolder }) { select(vm, section: .overview) } }
                }
                DisclosureGroup("Project files & tools") {
                    HStack {
                        Button("Check Project") { open(project, action: "info") }
                        Button("Import…") { importFolder(project) }
                        Button("Export…") { export(project) }
                        Button("Verify Lock") { verify(project) }
                        Button("Forget Shortcut") { projects.entries.removeAll { $0.id == project.id } }
                    }.padding(.top, 7)
                    Text("Forget removes this shortcut only; Linux files stay in the VM.").font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            }.padding(8).disabled(busy || !vms.contains { $0.folder.path == project.vmFolder })
        }
    }

    static func discoveredVMs(roots: [URL] = Paths.vmsRoots) -> [VMConfig] {
        var seen: Set<String> = []
        return VMConfig.all(roots: roots).filter { seen.insert($0.folder.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    private func refresh() {
        vms = fixtures ?? Self.discoveredVMs()
        if selectedFolder == nil { selectedFolder = vms.first(where: { $0.folder == state.config.folder })?.folder ?? vms.first?.folder }
        if fixtures != nil { statuses = Dictionary(uniqueKeysWithValues: vms.map { ($0.folder, previewRunning ? "Desktop running" : "Stopped") }) }
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
        stopping.insert(vm.folder)
        Task {
            if let port = UbuntuDataView.savedPort(vm), let error = await UbuntuDriveMount.eject(port: port) {
                problem = "Eject Linux drives before stopping: " + error
                stopping.remove(vm.folder)
                return
            }
            stopAfterEject(vm)
        }
    }
    private func stopAfterEject(_ vm: VMConfig) {
        if let why = Paths.startProblem(vm.folder) { problem = why; stopping.remove(vm.folder); return }
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
