import AppKit
import OmacVMWindow
import SwiftUI

struct UbuntuPortsView: View {
    @ObservedObject var state: AppState
    let config: VMConfig
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DeveloperNetwork()
    @State private var livePorts: [DeveloperPort] = []
    @State private var conflicts: Set<Int> = []
    @State private var checks: [Int: String] = [:]
    @State private var editing = false
    @State private var problem: String?
    @State private var running = false
    @State private var guestPort = "3000"
    @State private var macPort = "3000"
    @State private var shareLAN = false

    private var ports: [DeveloperPort] {
        let configured = settings.ports
        return configured + livePorts.filter { live in !configured.contains { $0.host == live.host } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connections — \(config.name)").font(.title2.bold())
                Spacer()
                Button("Advanced SSH & Network…") { editing = true }
                if !embedded { Button("Close") { dismiss() } }
            }
            Text("Only this Mac means localhost. LAN sharing uses your Mac's IP and a separate port for each VM.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            Text(running ? "Ubuntu is running. Configure new forwards while it is stopped; they publish on the next start." : "Ubuntu is stopped. Configured services will publish at its next start.").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Connect to this VM") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("From this Mac: SSH port \(config.sshPort)")
                                Spacer()
                                Button(settings.sshLAN ? "Manage LAN Access…" : "Allow LAN SSH…") { editing = true }
                                Button("Open Terminal") {
                                    do { try DeveloperActions.terminal(config, path: "/home/\(config.user)") }
                                    catch { problem = error.localizedDescription }
                                }
                            }
                            if settings.sshLAN {
                                Text("LAN SSH enabled on port \(settings.sshPort)").font(.headline)
                                ForEach(UbuntuNetworking.lanAddresses, id: \.self) { address in
                                    let command = "ssh -p \(settings.sshPort) \(config.user)@\(address)"
                                    HStack { Text(command).font(.system(.caption, design: .monospaced)); Spacer(); Button("Copy") { copy(command) } }
                                }
                            } else { Text("Other devices: private by default. Configure public keys and LAN access in Advanced SSH & Network.").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Publish a service") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) { Text("Linux port").font(.caption); TextField("Linux port", text: $guestPort) }.frame(width: 80)
                                Image(systemName: "arrow.right")
                                VStack(alignment: .leading, spacing: 4) { Text("Mac port").font(.caption); TextField("Mac port", text: $macPort) }.frame(width: 80)
                                Picker("Access", selection: $shareLAN) {
                                    Text("Only this Mac").tag(false)
                                    Text("Local network").tag(true)
                                }
                                Button("Publish") { publish() }.disabled(running)
                            }
                            Text("Run your app in Linux, then publish its port here. Local network also makes it reachable from other devices using your Mac’s address. Stop the VM to change publication.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                    ForEach(ports, id: \.host) { port in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Ubuntu port \(port.guest) → Mac port \(port.host)").font(.headline)
                                    Spacer(); Text(port.lan ? "LAN shared" : "Only this Mac").foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Open localhost:\(port.host)") { browser("127.0.0.1", port.host) }
                                    Button("Copy Local URL") { copy("http://127.0.0.1:\(port.host)") }
                                    Button("Test Port") { test(port) }
                                    Button("Remove Rule") { unpublish(port) }.disabled(running || !settings.ports.contains(where: { $0.host == port.host }))
                                }
                                if port.lan {
                                    ForEach(UbuntuNetworking.lanAddresses, id: \.self) { address in
                                        HStack { Text("http://\(address):\(port.host)").font(.system(.caption, design: .monospaced)); Spacer(); Button("Copy LAN URL") { copy("http://\(address):\(port.host)") } }
                                    }
                                }
                                if conflicts.contains(port.host) { Text("Mac port \(port.host) is occupied. Choose a different host port in settings.").foregroundStyle(.red) }
                                if let result = checks[port.host] { Text(result).font(.caption).foregroundStyle(.secondary) }
                            }.padding(6)
                        }
                    }
                    if ports.isEmpty { Text("No services published yet. Add a Linux port above to make it available from this Mac or your local network.").padding(.vertical, 16) }
                }
            }
            Text("Open uses HTTP; for databases and other protocols use the displayed address in your client. A successful local test does not verify access from another LAN device.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: embedded ? nil : 760, height: embedded ? nil : 620)
        .task {
            while !Task.isCancelled {
                refresh()
                let folder = config.folder
                let busy = await Task.detached { !Storage.busyFolders([folder]).isEmpty }.value
                if Task.isCancelled { return }
                running = busy
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $editing, onDismiss: refresh) { DeveloperSettingsView(state: state, config: config) }
    }
    private func refresh() {
        do { settings = try UbuntuNetworking.read(config); problem = nil } catch { problem = error.localizedDescription }
        let live = UbuntuNetworking.runtimeState(config)
        conflicts = Set(live?["conflicts"] as? [Int] ?? [])
        livePorts = (live?["ports"] as? [[String: Any]] ?? []).prefix(128).compactMap {
            guard let host = $0["host"] as? Int, let guest = $0["guest"] as? Int, (1024...65535).contains(host), (1...65535).contains(guest) else { return nil }
            return DeveloperPort(host: host, guest: guest, lan: $0["bind"] as? String == "0.0.0.0")
        }
    }
    private func publish() {
        guard let guest = Int(guestPort), let host = Int(macPort), (1...65535).contains(guest), (1024...65535).contains(host) else {
            problem = "Enter a Linux port from 1–65535 and a Mac port from 1024–65535."; return
        }
        var updated = settings
        updated.ports.append(DeveloperPort(host: host, guest: guest, lan: shareLAN))
        do { try UbuntuNetworking.save(updated, config: config); refresh() }
        catch { problem = error.localizedDescription }
    }
    private func unpublish(_ port: DeveloperPort) {
        var updated = settings
        updated.ports.removeAll { $0.host == port.host }
        do { try UbuntuNetworking.save(updated, config: config); refresh() }
        catch { problem = error.localizedDescription }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func browser(_ host: String, _ port: Int) { if let url = URL(string: "http://\(host):\(port)") { NSWorkspace.shared.open(url) } }
    private func test(_ port: DeveloperPort) {
        checks[port.host] = "Checking localhost…"
        Task {
            let reachable = await Task.detached { UbuntuNetworking.portReachable(port.host) }.value
            checks[port.host] = reachable ? "Mac port is reachable. Use Open to check the application response." : "Mac port is not reachable. Start Ubuntu and check its service is listening."
        }
    }
}
