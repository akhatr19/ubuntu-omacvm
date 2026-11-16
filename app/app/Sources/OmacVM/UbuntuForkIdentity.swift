import Foundation

enum UbuntuForkIdentity {
    /// Forks get fresh SSH/machine identity and one reboot before keys or
    /// host integration is enabled. The guest stamp makes interrupted boots safe.
    nonisolated static func prepare(_ config: VMConfig, agent: String, pid: pid_t) -> String? {
        let marker = config.folder.appendingPathComponent("fork-identity")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        guard let token = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              let key = VMKey.keyLine(folder: config.folder),
              let script = try? String(contentsOf: Paths.resources.appendingPathComponent("omacvm/src/ubuntu/guest/fork-identity.sh"), encoding: .utf8) else { return "Fork identity data is unreadable." }
        let deadline = Date().addingTimeInterval(240)
        func bootID() -> String? {
            if case .exited(0, let out) = GuestAgent.runAndWait(socketPath: agent, "/bin/cat", ["/proc/sys/kernel/random/boot_id"], seconds: 3) { return out }
            return nil
        }
        var old: String?
        while kill(pid, 0) == 0 && Date() < deadline && old == nil { old = bootID(); if old == nil { Thread.sleep(forTimeInterval: 1) } }
        guard let old else { return "Fork's guest agent did not become ready." }
        let name = Data(config.name.utf8).base64EncodedString()
        guard case .exited(0, let result) = GuestAgent.runAndWait(socketPath: agent, "/bin/bash", ["-c", script, "fork", config.user, token, name, key], seconds: 30) else { return "Could not prepare the fork's independent identity." }
        if result.trimmingCharacters(in: .whitespacesAndNewlines) == "already" {
            try? FileManager.default.removeItem(at: marker)
            return nil
        }
        while kill(pid, 0) == 0 && Date() < deadline {
            if let now = bootID(), now != old {
                try? FileManager.default.removeItem(at: marker)
                return nil
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return "Fork identity was prepared, but its reboot was not confirmed. Restart this VM before enabling host integrations."
    }
}
