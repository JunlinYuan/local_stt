import Foundation

/// A single word replacement rule: `from` → `to`.
public struct ReplacementRule: Identifiable, Codable, Sendable {
    public let id: UUID
    public let from: String
    public let to: String

    public init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }

    // Custom Decodable: `id` is optional in JSON (synthesized on load).
    enum CodingKeys: String, CodingKey {
        case id, from, to
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.from = try container.decode(String.self, forKey: .from)
        self.to = try container.decode(String.self, forKey: .to)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
    }
}
