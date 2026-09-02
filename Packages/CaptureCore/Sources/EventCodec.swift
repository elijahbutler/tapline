import Foundation

public enum EventCodecError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public enum EventCodec {
    public static func encode(_ event: CaptureEvent, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.format(date))
        }
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(event)
    }

    public static func decode(_ data: Data) throws -> CaptureEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            return try Date(value, strategy: Self.dateFormat)
        }
        let decoded = try decoder.decode(CaptureEvent.self, from: data)

        guard decoded.schemaVersion == CaptureEvent.currentSchemaVersion else {
            throw EventCodecError.unsupportedSchemaVersion(decoded.schemaVersion)
        }

        return CaptureEvent(
            schemaVersion: decoded.schemaVersion,
            id: decoded.id,
            type: decoded.type,
            occurredAt: decoded.occurredAt,
            capturedAt: decoded.capturedAt,
            source: decoded.source,
            payload: decoded.payload,
            media: decoded.media,
            links: decoded.links
        )
    }

    private static let dateFormat = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .colon,
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    private static func format(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded())
        let wholeSeconds = Int64(floor(Double(milliseconds) / 1_000))
        let remainder = milliseconds - wholeSeconds * 1_000

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let base = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))
        return String(format: "%@.%03lldZ", base, remainder)
    }
}
