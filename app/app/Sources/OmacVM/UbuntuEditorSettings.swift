import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum UbuntuEditorSettings {
    static var file: URL {
        let home = ProcessInfo.processInfo.environment["UVM_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UbuntuVM")
        return home.appendingPathComponent("editor.json")
    }
    static func command(in app: URL) -> URL? {
        ["code", "code-insiders"].map { app.appendingPathComponent("Contents/Resources/app/bin/" + $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    static var detected: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .flatMap { root in ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"].map { root.appendingPathComponent($0) } }
            .filter { command(in: $0) != nil }
    }
    static var selected: String {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8192,
              let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schema"] as? Int == 1 else { return "" }
        return value["application"] as? String ?? ""
    }
    static var current: URL? { selected.isEmpty ? detected.first : URL(fileURLWithPath: selected) }
    static var label: String { current?.lastPathComponent.localizedCaseInsensitiveContains("insiders") == true ? "VS Code Insiders" : "VS Code" }
    static var openLabel: String { label == "VS Code Insiders" ? "Open in Insiders" : "Open in VS Code" }
}

struct UbuntuEditorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = UbuntuEditorSettings.selected
    @State private var applications = UbuntuEditorSettings.detected
    @State private var problem: String?
    var onSaved: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("App Settings").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent) }
            Text("Default editor").font(.headline)
            Picker("VS Code installation", selection: $selected) {
                Text("Automatic — detect VS Code or Insiders").tag("")
                ForEach(applications, id: \.path) { app in Text(app.deletingPathExtension().lastPathComponent).tag(app.path) }
                if !selected.isEmpty && !applications.contains(where: { $0.path == selected }) { Text(selected).tag(selected) }
            }
            Text(selected.isEmpty ? (applications.first?.path ?? "No installation detected. Choose an application below.") : selected)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Choose another application…") {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
                if panel.runModal() == .OK, let app = panel.url {
                    guard UbuntuEditorSettings.command(in: app) != nil else { problem = "Choose a VS Code application containing its editor command."; return }
                    if !applications.contains(app) { applications.append(app) }; selected = app.path; problem = nil
                }
            }
            Text("Install Remote - SSH in the chosen editor. Project actions start Ubuntu, wait for SSH, then open the Linux folder in this installation.").foregroundStyle(.secondary)
            Divider()
            Text("Opening UbuntuVM always shows the launcher. VMs keep their current state until you choose Start, Open Project or Show Desktop.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
        }.padding(24).frame(width: 640)
    }
    private func save() {
        do {
            if !selected.isEmpty && UbuntuEditorSettings.command(in: URL(fileURLWithPath: selected)) == nil { problem = "This editor is unavailable. Choose another installation."; return }
            let file = UbuntuEditorSettings.file
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var value: [String: Any] = ["schema": 1]
            if !selected.isEmpty { value["application"] = selected }
            try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            onSaved(); dismiss()
        } catch { problem = error.localizedDescription }
    }
}
