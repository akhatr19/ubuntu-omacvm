import Foundation
import Combine

struct UbuntuProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var vmFolder: String
    var linuxPath: String
    var editor = "code"
    var lastOpened: Date?
}

@MainActor
final class UbuntuProjects: ObservableObject {
    static let key = "ubuntuProjects"
    @Published var entries: [UbuntuProject] { didSet { persist() } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 8 * 1024 * 1024,
           let records = try? JSONDecoder().decode([UbuntuProject].self, from: data) {
            entries = Array(records.prefix(256))
        } else { entries = [] }
    }
    func remember(_ project: UbuntuProject) {
        entries.removeAll { $0.vmFolder == project.vmFolder && $0.linuxPath == project.linuxPath }
        entries.insert(project, at: 0)
        entries = Array(entries.prefix(256))
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}
