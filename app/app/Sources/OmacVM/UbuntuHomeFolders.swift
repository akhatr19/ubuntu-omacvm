import Foundation

/// The GUI and managed environments use the same host folder settings and exports.
enum UbuntuHomeFolders {
    static func process(_ config: VMConfig, action: String) -> Process {
        let process = Process()
        process.executableURL = DeveloperActions.cli
        process.arguments = ["home-folders", "--vm", config.folder.path, "--qga", config.agentSocket.path, action]
        var env = ProcessInfo.processInfo.environment
        env["UVM_APP"] = Bundle.main.bundleURL.path
        env["UVM_TEST_MODE"] = config.name.hasPrefix("OmacVM Test-") ? "1" : "0"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        return process
    }

    static func arguments(_ config: VMConfig) throws -> [String] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ubuntu-home-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = process(config, action: "plan")
        process.arguments! += ["--output", output.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UbuntuPersonalData.failure(String(decoding: error, as: UTF8.self))
        }
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        guard let arguments = record?["arguments"] as? [String] else { throw UbuntuPersonalData.failure("Cannot prepare shared home folders.") }
        return arguments
    }

    static func status(_ config: VMConfig, pid: pid_t, message: String) {
        let value: [String: Any] = ["schema": 1, "pid": Int(pid), "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            try? data.write(to: config.folder.appendingPathComponent("logs/home-folders-status.json"), options: .atomic)
        }
    }

    static func message(_ config: VMConfig) -> String? {
        let value = try? UbuntuPersonalData.record(config.folder.appendingPathComponent("logs/home-folders-status.json"))
        return value?["message"] as? String
    }

    /// Use the launcher's held connection: QEMU permits only one agent client.
    static func install(_ config: VMConfig, agent: String, pid: pid_t, until deadline: Date) -> String? {
        func request(_ name: String, _ arguments: [String: Any]) throws -> Any {
            let data = try JSONSerialization.data(withJSONObject: ["execute": name, "arguments": arguments])
            guard let reply = GuestAgent.execute(socketPath: agent, String(decoding: data, as: UTF8.self)),
                  let bytes = reply.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let result = object["return"] else { throw UbuntuPersonalData.failure("Guest agent refused " + name) }
            return result
        }
        func run(_ script: String) throws {
            switch GuestAgent.runAndWait(socketPath: agent, "/bin/bash", ["-c", "exec 2>&1; set -e; " + script], seconds: 40) {
            case .exited(0, _): return
            case .exited(_, let output): throw UbuntuPersonalData.failure(output)
            default: throw UbuntuPersonalData.failure("Guest setup did not finish. Restart the VM and retry.")
            }
        }
        do {
            var ready = false
            while kill(pid, 0) == 0 && Date() < deadline {
                if case .exited(0, _) = GuestAgent.runAndWait(socketPath: agent, "/bin/true", [], seconds: 3) { ready = true; break }
                Thread.sleep(forTimeInterval: 1)
            }
            guard ready else { throw UbuntuPersonalData.failure("The VM guest agent did not become ready.") }
            let root = Paths.resources.appendingPathComponent("omacvm/src/ubuntu/guest")
            for (source, destination, mode) in [("home-folders.py", "/usr/local/bin/ubuntu-vm-home-folders", "755"),
                                                ("home-folders.service", "/etc/systemd/system/ubuntu-vm-home-folders.service", "644")] {
                let bytes = try Data(contentsOf: root.appendingPathComponent(source))
                let temporary = destination + ".new"
                guard let handle = try request("guest-file-open", ["path": temporary, "mode": "w"]) as? Int, handle > 0, handle <= Int(Int32.max) else {
                    throw UbuntuPersonalData.failure("Cannot upload the home folder helper.")
                }
                do {
                    defer { _ = try? request("guest-file-close", ["handle": handle]) }
                    for offset in stride(from: 0, to: bytes.count, by: 1024) {
                        let block = bytes.subdata(in: offset..<min(offset + 1024, bytes.count))
                        let result = try request("guest-file-write", ["handle": handle, "buf-b64": block.base64EncodedString()]) as? [String: Any]
                        guard result?["count"] as? Int == block.count else { throw UbuntuPersonalData.failure("Incomplete home folder helper upload.") }
                    }
                    _ = try request("guest-file-flush", ["handle": handle])
                }
                try run("chmod \(mode) \(temporary); mv \(temporary) \(destination)")
            }
            try run("systemctl daemon-reload; systemctl enable --now ubuntu-vm-home-folders.service")
            status(config, pid: pid, message: "Home folder setup completed for this startup.")
            return nil
        } catch {
            let message = "Shared home folders failed: " + error.localizedDescription
            status(config, pid: pid, message: message)
            return message
        }
    }
}
