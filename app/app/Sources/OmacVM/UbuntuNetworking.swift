import AppKit
import CryptoKit
import Darwin
import Foundation
import OmacVMWindow

/// Host-only settings; changing these does not rewrite the project's package lock.
enum UbuntuNetworking {
    static func read(_ config: VMConfig) throws -> DeveloperNetwork {
        let settings = try DeveloperNetwork.read(folder: config.folder)
        if let why = settings.problem(sshPort: config.sshPort) { throw HelperError.io(why) }
        if FastNetwork.isOn(config), settings.sshLAN || !settings.ports.isEmpty {
            throw HelperError.io("Turn off Fast network to use NAT port publication.")
        }
        return settings
    }

    static func save(_ settings: DeveloperNetwork, config: VMConfig) throws {
        guard Storage.busyFolders([config.folder]).isEmpty else { throw HelperError.io("Stop this VM before saving network settings.") }
        if let why = settings.problem(sshPort: config.sshPort) { throw HelperError.io(why) }
        if FastNetwork.isOn(config), settings.sshLAN || !settings.ports.isEmpty {
            throw HelperError.io("Turn off Fast network first. These published ports use the NAT network.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = config.folder.appendingPathComponent(DeveloperNetwork.file)
        try encoder.encode(settings).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func keyCommand(_ config: VMConfig, settings: DeveloperNetwork) throws -> [String] {
        let path = DeveloperActions.cli.deletingLastPathComponent().appendingPathComponent("src/dev/network.py")
        let source = try String(contentsOf: path, encoding: .utf8)
        return ["-c", source, "--guest", config.user, Data(settings.publicKeys.utf8).base64EncodedString()]
    }

    nonisolated static func apply(_ config: VMConfig, agent: String, qmp: String) -> String? {
        guard FileManager.default.fileExists(atPath: config.folder.appendingPathComponent(DeveloperNetwork.file).path) else { return nil }
        do {
            let settings = try read(config)
            let result = GuestAgent.runAndWait(socketPath: agent, "/usr/bin/python3", try keyCommand(config, settings: settings), seconds: 30)
            guard case .exited(0, _) = result else { return "UbuntuVM: SSH public keys could not be applied; LAN SSH was not published (\(result))." }
            if settings.sshLAN, !FastNetwork.isOn(config) {
                let connection = try QMPConnection(socketPath: qmp, identifierPrefix: "ubuntu-ssh")
                defer { connection.close() }
                let response = try connection.execute("human-monitor-command", arguments: ["command-line": "hostfwd_add net0 tcp:0.0.0.0:\(settings.sshPort)-:22"])
                if let text = response["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "UbuntuVM: LAN SSH was not published: \(text)"
                }
            }
            return "UbuntuVM: SSH public keys applied; LAN SSH \(settings.sshLAN ? "published on port \(settings.sshPort)" : "off")."
        } catch { return "UbuntuVM: network setup: \(error.localizedDescription)" }
    }

    nonisolated static func availablePort(start: Int, excluding: Set<Int>) -> Int? {
        for port in min(65535, max(1024, start))...65535 where !excluding.contains(port) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(port).bigEndian
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd)
            if result == 0 { return port }
        }
        return nil
    }

    nonisolated static func portReachable(_ port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&event, 1, 700) > 0 else { return false }
        var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    static var lanAddresses: [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name).hasPrefix("en"), interface.ifa_flags & UInt32(IFF_UP) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: host))
                }
            }
            item = interface.ifa_next
        }
        return Array(Set(addresses)).sorted()
    }

    static func runtimeState(_ config: VMConfig) -> [String: Any]? {
        let path = config.folder.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let file = URL(fileURLWithPath: "/tmp/uvm-\(getuid())/\(hash)/state.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
              let data = try? Data(contentsOf: file),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return state
    }

    static func showDesktop(_ config: VMConfig) -> Bool {
        guard let state = runtimeState(config), state["mode"] as? String == "desktop",
              let pid = state["qemu_pid"] as? Int32, pid > 0 else { return false }
        let marker = "file=" + config.disk.path.replacingOccurrences(of: ",", with: ",,") + ","
        guard Mac.run("/bin/ps", ["-p", "\(pid)", "-o", "args="]).contains(marker),
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    static func runtimeStatus(_ config: VMConfig) -> String {
        guard let state = runtimeState(config) else { return "Start the VM to publish its configured ports." }
        let ports = (state["ports"] as? [[String: Any]] ?? []).prefix(128).compactMap { port -> String? in
            guard let host = port["host"] as? Int, let guest = port["guest"] as? Int else { return nil }
            return "\(port["bind"] as? String ?? "127.0.0.1"):\(host) → Ubuntu:\(guest)"
        }
        let conflicts = (state["conflicts"] as? [Int] ?? []).prefix(128).map { "Port \($0) is already in use." }
        return ([state["ready"] as? Bool == true ? "Running" : "Starting"] + ports + conflicts).joined(separator: "\n")
    }
}
