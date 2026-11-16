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

    static func install(_ config: VMConfig) throws {
        let process = process(config, action: "install")
        let log = config.folder.appendingPathComponent("logs/home-folders.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle
        try process.run()
    }
}
