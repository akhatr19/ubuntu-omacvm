import Foundation
import SwiftUI

/// Ubuntu features use its own installer; enabling gestures explicitly installs its Mac helper.
struct UbuntuFeatureRow: View {
    @ObservedObject var state: AppState
    let feature: String
    let title: String
    let detail: String
    @State private var busy = false
    @State private var error: String?

    private var on: Bool { !VMRecord.isOff(feature, folder: state.config.folder) }

    var body: some View {
        SettingRow(title: title, subtitle: error ?? detail, subtitleIsError: error != nil, probe: "ubuntu-\(feature)") {
            if busy { ProgressView().controlSize(.small) }
            Button(on ? "Disable" : feature == "gestures" ? "Install Helper and Enable…" : "Enable") { change() }
                .disabled(busy || state.vmRunning())
        }
    }

    private func change() {
        let enable = !on
        guard feature == "gestures" && enable else {
            state.updateVM(features: ["\(feature)=\(enable ? "on" : "off")"])
            return
        }
        busy = true
        error = nil
        let script = Paths.scripts.appendingPathComponent("install-ubuntu-gestures.sh").path
        Task {
            let problem = await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script]
                do {
                    try p.run()
                    p.waitUntilExit()
                    return p.terminationStatus == 0 ? nil : "The Mac gestures helper could not be installed."
                } catch { return error.localizedDescription }
            }.value
            busy = false
            if let problem { error = problem }
            else { state.updateVM(features: ["gestures=on"]) }
        }
    }
}
