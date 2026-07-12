import Foundation
import Combine

struct LocalUserProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    let createdAt: Date
    var updatedAt: Date
}

final class LocalAccountStore: ObservableObject {
    @Published private(set) var profile: LocalUserProfile?

    private let defaultsKey = "psl.local.profile.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        load()
    }

    func createProfile(displayName: String) {
        let clean = sanitized(displayName)
        guard clean.count >= 2 else { return }

        profile = LocalUserProfile(
            id: UUID(),
            displayName: clean,
            createdAt: Date(),
            updatedAt: Date()
        )
        persist()
    }

    func renameProfile(_ displayName: String) {
        let clean = sanitized(displayName)
        guard clean.count >= 2, var value = profile else { return }

        value.displayName = clean
        value.updatedAt = Date()
        profile = value
        persist()
    }

    func deleteProfile() {
        profile = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            profile = nil
            return
        }
        profile = try? decoder.decode(LocalUserProfile.self, from: data)
    }

    private func persist() {
        guard let profile, let data = try? encoder.encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func sanitized(_ value: String) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(32)
        )
    }
}
