import Foundation

public struct InstallationIdentity: Codable, Hashable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }

    public static func loadOrCreate(
        defaults: UserDefaults = .standard,
        key: String = "tapline.installation-id"
    ) -> InstallationIdentity {
        if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) {
            return InstallationIdentity(id: id)
        }

        let identity = InstallationIdentity(id: UUID())
        defaults.set(identity.id.uuidString.lowercased(), forKey: key)
        return identity
    }
}
