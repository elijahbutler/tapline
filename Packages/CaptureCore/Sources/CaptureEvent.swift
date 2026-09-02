import Foundation

public enum EventType: String, Codable, CaseIterable, Hashable, Sendable {
    case buttonPressed = "button.pressed"
    case buttonReleased = "button.released"
    case audioStarted = "audio.started"
    case audioCaptured = "audio.captured"
    case transcriptCreated = "transcript.created"
    case deliveryTest = "delivery.test"
}

public enum EventSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case appleWatch = "apple_watch"
    case iPhone = "iphone"
    case bleWearable = "ble_wearable"
    case imported = "imported"
}

public struct EventSource: Codable, Hashable, Sendable {
    public let kind: EventSourceKind
    public let installationID: UUID
    public let model: String?
    public let osVersion: String?
    public let appVersion: String
    public let adapter: String

    public init(
        kind: EventSourceKind,
        installationID: UUID,
        model: String? = nil,
        osVersion: String? = nil,
        appVersion: String,
        adapter: String
    ) {
        self.kind = kind
        self.installationID = installationID
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.adapter = adapter
    }

    private enum CodingKeys: String, CodingKey {
        case kind, installationID, model, osVersion, appVersion, adapter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(EventSourceKind.self, forKey: .kind)
        installationID = try container.decodeUUID(forKey: .installationID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        adapter = try container.decode(String.self, forKey: .adapter)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(installationID, forKey: .installationID)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(adapter, forKey: .adapter)
    }
}

public struct MediaReference: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let role: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String
    public let durationMilliseconds: Int?
    public let sampleRateHertz: Int?
    public let channelCount: Int?

    public init(
        id: UUID,
        role: String,
        mediaType: String,
        byteCount: Int64,
        sha256: String,
        durationMilliseconds: Int? = nil,
        sampleRateHertz: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.durationMilliseconds = durationMilliseconds
        self.sampleRateHertz = sampleRateHertz
        self.channelCount = channelCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, mediaType, byteCount, sha256
        case durationMilliseconds, sampleRateHertz, channelCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeUUID(forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        sampleRateHertz = try container.decodeIfPresent(Int.self, forKey: .sampleRateHertz)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(sha256, forKey: .sha256)
        try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(sampleRateHertz, forKey: .sampleRateHertz)
        try container.encodeIfPresent(channelCount, forKey: .channelCount)
    }
}

public struct EventLinks: Codable, Hashable, Sendable {
    public let derivedFrom: UUID?
    public let sessionID: UUID?

    public init(derivedFrom: UUID? = nil, sessionID: UUID? = nil) {
        self.derivedFrom = derivedFrom
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case derivedFrom, sessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        derivedFrom = try container.decodeUUIDIfPresent(forKey: .derivedFrom)
        sessionID = try container.decodeUUIDIfPresent(forKey: .sessionID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(derivedFrom, forKey: .derivedFrom)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
    }
}

public struct CaptureEvent: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let type: EventType
    public let occurredAt: Date
    public let capturedAt: Date
    public let source: EventSource
    public let payload: [String: JSONValue]
    public let media: [MediaReference]
    public let links: EventLinks

    public init(
        schemaVersion: Int = CaptureEvent.currentSchemaVersion,
        id: UUID = UUID(),
        type: EventType,
        occurredAt: Date,
        capturedAt: Date,
        source: EventSource,
        payload: [String: JSONValue] = [:],
        media: [MediaReference] = [],
        links: EventLinks = EventLinks()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.type = type
        self.occurredAt = Self.millisecondPrecision(occurredAt)
        self.capturedAt = Self.millisecondPrecision(capturedAt)
        self.source = source
        self.payload = payload
        self.media = media
        self.links = links
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, type, occurredAt, capturedAt, source, payload, media, links
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            id: try container.decodeUUID(forKey: .id),
            type: try container.decode(EventType.self, forKey: .type),
            occurredAt: try container.decode(Date.self, forKey: .occurredAt),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            source: try container.decode(EventSource.self, forKey: .source),
            payload: try container.decode([String: JSONValue].self, forKey: .payload),
            media: try container.decode([MediaReference].self, forKey: .media),
            links: try container.decode(EventLinks.self, forKey: .links)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(source, forKey: .source)
        try container.encode(payload, forKey: .payload)
        try container.encode(media, forKey: .media)
        try container.encode(links, forKey: .links)
    }

    public static func deliveryTest(
        destinationID: UUID,
        source: EventSource,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> CaptureEvent {
        CaptureEvent(
            id: id,
            type: .deliveryTest,
            occurredAt: now,
            capturedAt: now,
            source: source,
            payload: [
                "destinationID": .string(destinationID.uuidString.lowercased()),
                "message": .string("Tapline destination test"),
            ]
        )
    }

    private static func millisecondPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    public static func == (lhs: CaptureEvent, rhs: CaptureEvent) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.id == rhs.id
            && lhs.type == rhs.type
            && milliseconds(lhs.occurredAt) == milliseconds(rhs.occurredAt)
            && milliseconds(lhs.capturedAt) == milliseconds(rhs.capturedAt)
            && lhs.source == rhs.source
            && lhs.payload == rhs.payload
            && lhs.media == rhs.media
            && lhs.links == rhs.links
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion)
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(Self.milliseconds(occurredAt))
        hasher.combine(Self.milliseconds(capturedAt))
        hasher.combine(source)
        hasher.combine(payload)
        hasher.combine(media)
        hasher.combine(links)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
