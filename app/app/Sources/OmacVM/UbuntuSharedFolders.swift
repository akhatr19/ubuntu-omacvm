import Foundation

/// VM startup reconnects live folders; no shell or developer tools on the Mac.
enum UbuntuSharedFolders {
    static func arguments(_ config: VMConfig) throws -> [String] {
        let file = config.folder.appendingPathComponent("shared-folders.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let record = try UbuntuPersonalData.record(file)
        guard let folders = record["folders"] as? [[String: Any]], folders.count <= 16 else { throw UbuntuPersonalData.failure("Invalid shared folder settings.") }
        return try folders.flatMap { folder in
            guard let id = folder["id"] as? String, id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
                throw UbuntuPersonalData.failure("Invalid shared folder ID.")
            }
            return ["-smbios", "type=11,value=uvm.shared=" + id]
        }
    }

    static func watch(_ config: VMConfig, pid: Int32) throws {
        guard FileManager.default.fileExists(atPath: config.folder.appendingPathComponent("shared-folders.json").path) else { return }
        let process = Process()
        process.executableURL = DeveloperActions.cli
        process.arguments = ["sharing", "--vm", config.folder.path, "--qga", config.agentSocket.path, "watch", "--pid", String(pid)]
        var env = ProcessInfo.processInfo.environment
        env["UVM_APP"] = Bundle.main.bundleURL.path
        env["UVM_VMS_ROOT"] = config.folder.deletingLastPathComponent().path
        env["UVM_TEST_MODE"] = config.name.hasPrefix("OmacVM Test-") ? "1" : "0"
        process.environment = env
        let log = config.folder.appendingPathComponent("logs/shared-folders.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        try process.run()
    }
}
