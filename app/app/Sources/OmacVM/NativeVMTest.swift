import AppKit

/// Exercise the real native launcher without a window, Mac input, or the user's clipboard.
/// Enabled only in a test identity, and only for explicitly named disposable VMs.
@MainActor
enum NativeVMTest {
    static func run(folder: URL) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        guard folder.lastPathComponent.hasPrefix("OmacVM Test-"), let config = VMConfig.load(from: folder),
              config.isReady else { exit(2) }
        setenv("OMACVM_COCOA_HIDDEN", "1", 1)
        setenv("OMACVM_TEST_PASTEBOARD", "org.omacvm.test." + UUID().uuidString, 1)
        UserDefaults.standard.set(folder.deletingLastPathComponent().path, forKey: "vmsRoot")
        if Paths.startProblem(folder) != nil { exit(2) }
        Settings.startFullScreen = false
        let runner = Runner(config: config)
        runner.onExit = { exit($0 == 0 ? 0 : 1) }
        do {
            try runner.start()
            let value: [String: Any] = ["pid": Int(runner.process!.processIdentifier), "arguments": runner.process!.arguments ?? []]
            try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent("logs/native-launch.json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        runner.process?.terminate()
        exit(1)
    }
}
