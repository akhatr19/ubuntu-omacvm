#!/bin/bash
# Project shortcuts share VMs; forgetting a shortcut must never delete files.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/main.swift" <<'SWIFT'
import Foundation
MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let defaults = UserDefaults(suiteName: root.appendingPathComponent("defaults").path)!
    let store = UbuntuProjects(defaults: defaults)
    let vm = root.appendingPathComponent("vm")
    try! Data("preserve".utf8).write(to: vm)
    var project = UbuntuProject(name: "One", vmFolder: vm.path, linuxPath: "/home/u/one")
    store.remember(project)
    store.remember(UbuntuProject(name: "Two", vmFolder: vm.path, linuxPath: "/home/u/two"))
    precondition(store.entries.count == 2, "projects must be able to share a VM")
    project.name = "Renamed"; project.editor = "terminal"
    store.remember(project)
    precondition(store.entries.count == 2, "remembering the same folder must update its shortcut")
    let loaded = UbuntuProjects(defaults: defaults)
    precondition(loaded.entries.first?.editor == "terminal", "preferred editor must survive reload")
    loaded.entries.removeAll()
    precondition((try! String(contentsOf: vm, encoding: .utf8)) == "preserve", "forgetting projects must not delete VM files")
    for index in 0..<200 {
        loaded.remember(UbuntuProject(name: "Project \(index)", vmFolder: vm.path,
            linuxPath: "/home/u/" + String(repeating: "x", count: 1400) + String(index)))
    }
    precondition(UbuntuProjects(defaults: defaults).entries.count == 200, "long project paths must survive reload")
    defaults.set(Data("invalid".utf8), forKey: UbuntuProjects.key)
    precondition(UbuntuProjects(defaults: defaults).entries.isEmpty, "bad saved metadata must not crash")
    print("PASS shared VM, duplicate folder, editor persistence, forget preserves data, invalid metadata")
}
SWIFT
swiftc -o "$T/tests" "$R/app/app/Sources/OmacVM/UbuntuProjects.swift" "$T/main.swift"
"$T/tests" "$T"
