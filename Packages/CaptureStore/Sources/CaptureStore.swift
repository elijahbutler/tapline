import CaptureCore
import DeliveryKit
import Foundation
import GRDB

public actor CaptureStore {
    private let database: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()

        try Self.makeMigrator().migrate(database)
    }

    public static func applicationDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = "app.tapline.ios"
    ) throws -> URL {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "tapline.sqlite", directoryHint: .notDirectory)
    }

    @discardableResult
    public func saveDestination(_ destination: Destination, now: Date = Date()) throws -> Destination {
        try destination.validate()
        let data = try encoder.encode(destination)

        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO destinations (id, name, enabled, definition_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        enabled = excluded.enabled,
                        definition_json = excluded.definition_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    destination.id.uuidString.lowercased(),
                    destination.name,
                    destination.enabled,
                    data,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                ]
            )
        }
        return destination
    }

    public func destinations() throws -> [Destination] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT definition_json FROM destinations ORDER BY name COLLATE NOCASE"
            )
            return try rows.map { row in
                let data: Data = row["definition_json"]
                return try decoder.decode(Destination.self, from: data)
            }
        }
    }

    public func destination(id: UUID) throws -> Destination? {
        try database.read { database in
            guard let data = try Data.fetchOne(
                database,
                sql: "SELECT definition_json FROM destinations WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ) else {
                return nil
            }
            return try decoder.decode(Destination.self, from: data)
        }
    }

    public func deleteDestination(id: UUID) throws {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM destinations WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            )
        }
    }

    @discardableResult
    public func enqueue(
        _ event: CaptureEvent,
        destinationIDs: [UUID],
        now: Date = Date()
    ) throws -> [DeliveryJob] {
        let eventData = try EventCodec.encode(event)

        return try database.write { database in
            if let existing = try Data.fetchOne(
                database,
                sql: "SELECT event_json FROM events WHERE id = ?",
                arguments: [event.id.uuidString.lowercased()]
            ) {
                guard existing == eventData else {
                    throw CaptureStoreError.eventIDConflict(event.id)
                }
            } else {
                try database.execute(
                    sql: """
                        INSERT INTO events (id, type, occurred_at, event_json, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        event.id.uuidString.lowercased(),
                        event.type.rawValue,
                        event.occurredAt.timeIntervalSince1970,
                        eventData,
                        now.timeIntervalSince1970,
                    ]
                )
            }

            var jobs: [DeliveryJob] = []
            for destinationID in destinationIDs {
                let exists = try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS(SELECT 1 FROM destinations WHERE id = ?)",
                    arguments: [destinationID.uuidString.lowercased()]
                ) ?? false
                guard exists else {
                    throw CaptureStoreError.missingDestination(destinationID)
                }

                if let existing = try fetchJob(
                    database: database,
                    eventID: event.id,
                    destinationID: destinationID
                ) {
                    jobs.append(existing)
                    continue
                }

                let job = DeliveryJob(
                    eventID: event.id,
                    destinationID: destinationID,
                    createdAt: now,
                    updatedAt: now
                )
                try insert(job, database: database)
                jobs.append(job)
            }
            return jobs
        }
    }

    @discardableResult
    public func routeAndEnqueue(_ event: CaptureEvent, now: Date = Date()) throws -> [DeliveryJob] {
        let matchingIDs = try destinations()
            .filter { $0.enabled && $0.filter.matches(event) }
            .map(\.id)
        return try enqueue(event, destinationIDs: matchingIDs, now: now)
    }

    public func queueItems() throws -> [QueueItem] {
        try database.read { database in
            let eventRows = try Row.fetchAll(
                database,
                sql: "SELECT event_json FROM events ORDER BY occurred_at DESC"
            )
            return try eventRows.map { row in
                let data: Data = row["event_json"]
                let event = try EventCodec.decode(data)
                let jobs = try deliveryJobs(database: database, eventID: event.id)
                return QueueItem(event: event, deliveries: jobs)
            }
        }
    }

    public func lease(
        jobID: UUID,
        owner: UUID,
        now: Date = Date(),
        duration: TimeInterval = 60
    ) throws -> DeliveryEnvelope? {
        try database.write { database in
            guard var job = try fetchJob(database: database, id: jobID) else { return nil }
            let eligibleStates: Set<DeliveryState> = [.queued, .retryWait]
            guard eligibleStates.contains(job.state),
                  job.nextAttemptAt == nil || job.nextAttemptAt! <= now,
                  job.leaseExpiresAt == nil || job.leaseExpiresAt! <= now
            else {
                return nil
            }

            job.state = .attempting
            job.attemptCount += 1
            job.leaseOwner = owner
            job.leaseExpiresAt = now.addingTimeInterval(duration)
            job.updatedAt = now
            try update(job, database: database)

            guard let eventData = try Data.fetchOne(
                database,
                sql: "SELECT event_json FROM events WHERE id = ?",
                arguments: [job.eventID.uuidString.lowercased()]
            ), let destinationData = try Data.fetchOne(
                database,
                sql: "SELECT definition_json FROM destinations WHERE id = ?",
                arguments: [job.destinationID.uuidString.lowercased()]
            ) else {
                throw CaptureStoreError.corruptRecord(job.id.uuidString)
            }

            let event = try EventCodec.decode(eventData)
            let destination = try decoder.decode(Destination.self, from: destinationData)
            return DeliveryEnvelope(job: job, event: event, destination: destination)
        }
    }

    public func record(
        _ disposition: DeliveryDisposition,
        for jobID: UUID,
        now: Date = Date()
    ) throws {
        try database.write { database in
            guard var job = try fetchJob(database: database, id: jobID) else { return }
            job.leaseOwner = nil
            job.leaseExpiresAt = nil
            job.updatedAt = now

            switch disposition {
            case let .delivered(statusCode):
                job.state = .delivered
                job.nextAttemptAt = nil
                job.lastHTTPStatus = statusCode
                job.lastErrorCode = nil
            case let .retry(at, reason):
                job.state = .retryWait
                job.nextAttemptAt = at
                job.lastErrorCode = Self.redactedErrorCode(reason)
            case let .pausedAuthentication(statusCode):
                job.state = .pausedAuthentication
                job.nextAttemptAt = nil
                job.lastHTTPStatus = statusCode
                job.lastErrorCode = "authentication_required"
            case let .permanentFailure(statusCode, reason):
                job.state = .failedPermanent
                job.nextAttemptAt = nil
                job.lastHTTPStatus = statusCode == 0 ? nil : statusCode
                job.lastErrorCode = Self.redactedErrorCode(reason)
            }
            try update(job, database: database)
        }
    }

    public func requeue(jobID: UUID, now: Date = Date()) throws {
        try database.write { database in
            guard var job = try fetchJob(database: database, id: jobID) else { return }
            job.state = .queued
            job.nextAttemptAt = nil
            job.leaseOwner = nil
            job.leaseExpiresAt = nil
            job.lastErrorCode = nil
            job.updatedAt = now
            try update(job, database: database)
        }
    }

    public func deleteEvent(id: UUID) throws {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM events WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            )
        }
    }

    public func readyJobIDs(now: Date = Date(), limit: Int = 20) throws -> [UUID] {
        try database.read { database in
            let rows = try String.fetchAll(
                database,
                sql: """
                    SELECT jobs.id FROM delivery_jobs AS jobs
                    JOIN destinations AS destinations ON destinations.id = jobs.destination_id
                    WHERE destinations.enabled = 1
                      AND jobs.state IN (?, ?)
                      AND (jobs.next_attempt_at IS NULL OR jobs.next_attempt_at <= ?)
                      AND (jobs.lease_expires_at IS NULL OR jobs.lease_expires_at <= ?)
                    ORDER BY COALESCE(jobs.next_attempt_at, jobs.created_at), jobs.created_at
                    LIMIT ?
                    """,
                arguments: [
                    DeliveryState.queued.rawValue,
                    DeliveryState.retryWait.rawValue,
                    now.timeIntervalSince1970,
                    now.timeIntervalSince1970,
                    limit,
                ]
            )
            return rows.compactMap(UUID.init(uuidString:))
        }
    }

    public func deleteAllEvents() throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM events")
        }
    }

    public func exportSnapshot(now: Date = Date()) throws -> ExportSnapshot {
        let items = try queueItems()
        return try ExportSnapshot(
            exportedAt: now,
            events: items.map(\.event),
            destinations: destinations(),
            deliveries: items.flatMap(\.deliveries)
        )
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("phase1-v1") { database in
            try database.create(table: "destinations") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("enabled", .boolean).notNull()
                table.column("definition_json", .blob).notNull()
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }

            try database.create(table: "events") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull()
                table.column("occurred_at", .double).notNull()
                table.column("event_json", .blob).notNull()
                table.column("created_at", .double).notNull()
            }

            try database.create(table: "delivery_jobs") { table in
                table.column("id", .text).primaryKey()
                table.column("event_id", .text)
                    .notNull()
                    .references("events", onDelete: .cascade)
                table.column("destination_id", .text)
                    .notNull()
                    .references("destinations", onDelete: .cascade)
                table.column("state", .text).notNull()
                table.column("attempt_count", .integer).notNull()
                table.column("next_attempt_at", .double)
                table.column("lease_owner", .text)
                table.column("lease_expires_at", .double)
                table.column("last_http_status", .integer)
                table.column("last_error_code", .text)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
                table.uniqueKey(["event_id", "destination_id"])
            }

            try database.create(
                index: "delivery_jobs_ready",
                on: "delivery_jobs",
                columns: ["state", "next_attempt_at"]
            )
        }
        return migrator
    }

    private func insert(_ job: DeliveryJob, database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO delivery_jobs (
                    id, event_id, destination_id, state, attempt_count, next_attempt_at,
                    lease_owner, lease_expires_at, last_http_status, last_error_code,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: arguments(for: job)
        )
    }

    private func update(_ job: DeliveryJob, database: Database) throws {
        try database.execute(
            sql: """
                UPDATE delivery_jobs SET
                    state = ?, attempt_count = ?, next_attempt_at = ?, lease_owner = ?,
                    lease_expires_at = ?, last_http_status = ?, last_error_code = ?, updated_at = ?
                WHERE id = ?
                """,
            arguments: [
                job.state.rawValue,
                job.attemptCount,
                job.nextAttemptAt?.timeIntervalSince1970,
                job.leaseOwner?.uuidString.lowercased(),
                job.leaseExpiresAt?.timeIntervalSince1970,
                job.lastHTTPStatus,
                job.lastErrorCode,
                job.updatedAt.timeIntervalSince1970,
                job.id.uuidString.lowercased(),
            ]
        )
    }

    private func arguments(for job: DeliveryJob) -> StatementArguments {
        [
            job.id.uuidString.lowercased(),
            job.eventID.uuidString.lowercased(),
            job.destinationID.uuidString.lowercased(),
            job.state.rawValue,
            job.attemptCount,
            job.nextAttemptAt?.timeIntervalSince1970,
            job.leaseOwner?.uuidString.lowercased(),
            job.leaseExpiresAt?.timeIntervalSince1970,
            job.lastHTTPStatus,
            job.lastErrorCode,
            job.createdAt.timeIntervalSince1970,
            job.updatedAt.timeIntervalSince1970,
        ]
    }

    private func fetchJob(database: Database, id: UUID) throws -> DeliveryJob? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM delivery_jobs WHERE id = ?",
            arguments: [id.uuidString.lowercased()]
        ) else {
            return nil
        }
        return try decodeJob(row)
    }

    private func fetchJob(
        database: Database,
        eventID: UUID,
        destinationID: UUID
    ) throws -> DeliveryJob? {
        guard let row = try Row.fetchOne(
            database,
            sql: "SELECT * FROM delivery_jobs WHERE event_id = ? AND destination_id = ?",
            arguments: [eventID.uuidString.lowercased(), destinationID.uuidString.lowercased()]
        ) else {
            return nil
        }
        return try decodeJob(row)
    }

    private func deliveryJobs(database: Database, eventID: UUID) throws -> [DeliveryJob] {
        try Row.fetchAll(
            database,
            sql: "SELECT * FROM delivery_jobs WHERE event_id = ? ORDER BY created_at",
            arguments: [eventID.uuidString.lowercased()]
        ).map(decodeJob)
    }

    private func decodeJob(_ row: Row) throws -> DeliveryJob {
        let idString: String = row["id"]
        let eventIDString: String = row["event_id"]
        let destinationIDString: String = row["destination_id"]
        let stateString: String = row["state"]
        let nextAttempt: Double? = row["next_attempt_at"]
        let leaseOwnerString: String? = row["lease_owner"]
        let leaseExpiration: Double? = row["lease_expires_at"]
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]

        guard let id = UUID(uuidString: idString),
              let eventID = UUID(uuidString: eventIDString),
              let destinationID = UUID(uuidString: destinationIDString),
              let state = DeliveryState(rawValue: stateString)
        else {
            throw CaptureStoreError.corruptRecord(idString)
        }

        return DeliveryJob(
            id: id,
            eventID: eventID,
            destinationID: destinationID,
            state: state,
            attemptCount: row["attempt_count"],
            nextAttemptAt: nextAttempt.map(Date.init(timeIntervalSince1970:)),
            leaseOwner: leaseOwnerString.flatMap(UUID.init(uuidString:)),
            leaseExpiresAt: leaseExpiration.map(Date.init(timeIntervalSince1970:)),
            lastHTTPStatus: row["last_http_status"],
            lastErrorCode: row["last_error_code"],
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func redactedErrorCode(_ reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.hasPrefix("http ") { return normalized.replacingOccurrences(of: " ", with: "_") }
        if normalized.contains("timed out") { return "network_timeout" }
        if normalized.contains("offline") || normalized.contains("not connected") { return "network_offline" }
        if normalized.contains("certificate") || normalized.contains("ssl") { return "tls_failure" }
        return "delivery_failure"
    }
}
